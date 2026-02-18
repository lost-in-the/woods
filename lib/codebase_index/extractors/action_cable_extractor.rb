# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ActionCableExtractor handles ActionCable channel extraction via runtime introspection.
    #
    # Reads `ActionCable::Channel::Base.descendants` to discover channels, then inspects
    # each channel's stream subscriptions, actions, broadcast patterns, and source code.
    # Each channel becomes one ExtractedUnit with metadata about streams, actions, and
    # broadcast patterns.
    #
    # @example
    #   extractor = ActionCableExtractor.new
    #   units = extractor.extract_all
    #   chat = units.find { |u| u.identifier == "ChatChannel" }
    #   chat.metadata[:stream_names]  #=> ["chat_room_#{params[:room_id]}"]
    #   chat.metadata[:actions]       #=> ["speak", "typing"]
    #
    class ActionCableExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Lifecycle methods that are not user-defined actions
      LIFECYCLE_METHODS = %i[subscribed unsubscribed].freeze

      def initialize
        # No directories to scan — this is runtime introspection
      end

      # Extract all ActionCable channels as ExtractedUnits.
      #
      # @return [Array<ExtractedUnit>] List of channel units
      def extract_all
        return [] unless action_cable_available?

        channels = channel_descendants
        return [] if channels.empty?

        channels.filter_map { |klass| extract_channel(klass) }
      end

      # Extract a single channel class into an ExtractedUnit.
      #
      # Public for incremental re-extraction via CLASS_BASED dispatch.
      #
      # @param klass [Class] A channel subclass
      # @return [ExtractedUnit, nil]
      def extract_channel(klass)
        name = klass.name
        file_path = discover_source_path(klass, name)
        source = read_source(file_path)
        own_methods = klass.instance_methods(false)

        unit = ExtractedUnit.new(
          type: :action_cable_channel,
          identifier: name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(name)
        unit.source_code = source
        unit.metadata = build_metadata(source, own_methods)
        unit.dependencies = source.empty? ? [] : scan_common_dependencies(source)

        unit
      rescue StandardError => e
        log_extraction_error(name, e)
        nil
      end

      private

      # Check if ActionCable::Channel::Base is defined.
      #
      # @return [Boolean]
      def action_cable_available?
        defined?(ActionCable::Channel::Base)
      end

      # Retrieve channel descendants, filtering out abstract bases and anonymous classes.
      #
      # @return [Array<Class>]
      def channel_descendants
        ActionCable::Channel::Base.descendants.reject do |klass|
          klass.name.nil? || klass.name == 'ApplicationCable::Channel'
        end
      end

      # Discover the source file path for a channel class.
      #
      # Tries source_location on instance methods, then falls back to
      # the Rails convention path.
      #
      # @param klass [Class] The channel class
      # @param name [String] The channel class name
      # @return [String, nil]
      def discover_source_path(klass, name)
        path = source_location_from_methods(klass)
        return path if path

        convention_fallback(name)
      end

      # Try to get source_location from the channel's instance methods.
      # Tries subscribed first, then any other instance method.
      #
      # @param klass [Class] The channel class
      # @return [String, nil]
      def source_location_from_methods(klass)
        try_methods = [:subscribed] + (klass.instance_methods(false) - [:subscribed])
        try_methods.each do |method_name|
          location = klass.instance_method(method_name).source_location
          return location[0] if location
        rescue NameError, TypeError
          next
        end
        nil
      rescue StandardError
        nil
      end

      # Fall back to Rails convention path for channel files.
      #
      # @param name [String] Channel class name
      # @return [String, nil]
      def convention_fallback(name)
        return nil unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

        path = Rails.root.join('app', 'channels', "#{name.underscore}.rb").to_s
        File.exist?(path) ? path : nil
      end

      # Read source code from a file path.
      #
      # @param file_path [String, nil]
      # @return [String]
      def read_source(file_path)
        return '' unless file_path && File.exist?(file_path)

        File.read(file_path)
      rescue StandardError
        ''
      end

      # Build metadata hash for a channel.
      #
      # @param source [String] Channel source code
      # @param own_methods [Array<Symbol>] Methods defined directly on the channel
      # @return [Hash]
      def build_metadata(source, own_methods)
        {
          stream_names: detect_stream_names(source),
          actions: detect_actions(own_methods),
          has_subscribed: own_methods.include?(:subscribed),
          has_unsubscribed: own_methods.include?(:unsubscribed),
          broadcasts_to: detect_broadcasts(source),
          loc: count_loc(source)
        }
      end

      # Detect stream names from stream_from and stream_for calls.
      #
      # @param source [String] Channel source code
      # @return [Array<String>]
      def detect_stream_names(source)
        streams = []

        # stream_from "string" or stream_from 'string' (also catches interpolated strings)
        streams.concat(source.scan(/stream_from\s+["']([^"']+)["']/).flatten)

        # stream_for model
        streams.concat(source.scan(/stream_for\s+(\w+)/).map { |m| "stream_for:#{m[0]}" })

        streams.uniq
      end

      # Detect action methods (public instance methods minus lifecycle methods).
      #
      # @param own_methods [Array<Symbol>] Methods defined directly on the channel
      # @return [Array<String>]
      def detect_actions(own_methods)
        (own_methods - LIFECYCLE_METHODS).map(&:to_s)
      end

      # Detect broadcast patterns in source code.
      #
      # @param source [String] Channel source code
      # @return [Array<String>]
      def detect_broadcasts(source)
        broadcasts = []

        # ActionCable.server.broadcast("channel_name", ...)
        broadcasts.concat(source.scan(/ActionCable\.server\.broadcast\(\s*["']([^"']+)["']/).flatten)

        # SomeChannel.broadcast_to(target, ...)
        broadcasts.concat(source.scan(/\w+\.broadcast_to\(\s*(\w+)/).map { |m| "broadcast_to:#{m[0]}" })

        broadcasts.uniq
      end

      # Count non-blank, non-comment lines.
      #
      # @param source [String]
      # @return [Integer]
      def count_loc(source)
        return 0 if source.empty?

        source.each_line.count do |line|
          stripped = line.strip
          !stripped.empty? && !stripped.start_with?('#')
        end
      end

      # Log a channel extraction error.
      #
      # @param name [String] Channel class name
      # @param error [StandardError]
      def log_extraction_error(name, error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.error("Failed to extract channel #{name}: #{error.message}")
      end
    end
  end
end
