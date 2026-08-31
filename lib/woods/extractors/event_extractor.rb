# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module Woods
  module Extractors
    # EventExtractor discovers event publishing and subscribing patterns across the app.
    #
    # Scans +app/**/*.rb+ for two event system conventions:
    # - ActiveSupport::Notifications: +instrument+ (publish) and +subscribe+ (consume)
    # - Wisper: +publish+/+broadcast+ (publish) and +on(:event_name)+ (subscribe)
    #
    # Uses a two-pass approach:
    # 1. Scan all files, collecting publishers and subscribers per event name
    # 2. Merge by event name → one ExtractedUnit per unique event
    #
    # @example
    #   extractor = EventExtractor.new
    #   units = extractor.extract_all
    #   event = units.find { |u| u.identifier == "order.completed" }
    #   event.metadata[:publishers]  # => ["app/services/order_service.rb"]
    #   event.metadata[:subscribers] # => ["app/listeners/order_listener.rb"]
    #   event.metadata[:pattern]     # => :active_support
    #
    class EventExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      APP_DIRECTORIES = %w[app].freeze

      def initialize
        @directories = APP_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
      end

      # Extract all event units using a two-pass approach.
      #
      # Pass 1: Collect publish/subscribe references across all app files.
      # Pass 2: Merge by event name — one ExtractedUnit per unique event.
      #
      # @return [Array<ExtractedUnit>] One unit per unique event name
      def extract_all
        event_map = {}

        find_files_in_directories(@directories).each do |file_path|
          scan_file(file_path, event_map)
        end

        event_map.filter_map { |event_name, data| build_unit(event_name, data) }
      end

      # Scan a single file for event publishing and subscribing patterns.
      #
      # Mutates +event_map+ in place, registering publishers and subscribers.
      #
      # @param file_path [String] Path to the Ruby file
      # @param event_map [Hash] Mutable map of event_name => {publishers:, subscribers:, pattern:}
      # @return [void]
      def scan_file(file_path, event_map)
        source = cached_source(file_path)
        unless source
          Rails.logger.error("Failed to scan #{file_path} for events: file unreadable")
          return
        end

        scan_active_support_notifications(source, file_path, event_map)
        scan_wisper_patterns(source, file_path, event_map)
      rescue StandardError => e
        Rails.logger.error("Failed to scan #{file_path} for events: #{e.message}")
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Pattern Detection
      # ──────────────────────────────────────────────────────────────────────

      # Scan for ActiveSupport::Notifications instrument and subscribe patterns.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] File path
      # @param event_map [Hash] Mutable event map
      # @return [void]
      def scan_active_support_notifications(source, file_path, event_map)
        source.scan(/ActiveSupport::Notifications\.instrument\s*\(\s*["']([^"']+)["']/) do |m|
          register_publisher(event_map, m[0], file_path, :active_support)
        end

        source.scan(/ActiveSupport::Notifications\.subscribe\s*\(\s*["']([^"']+)["']/) do |m|
          register_subscriber(event_map, m[0], file_path, :active_support)
        end
      end

      # Scan for Wisper event patterns.
      #
      # Publishers must have Wisper context in the file (include Wisper or use
      # Wisper directly). Subscribers are detected via +.on(:event_name)+ chains.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] File path
      # @param event_map [Hash] Mutable event map
      # @return [void]
      def scan_wisper_patterns(source, file_path, event_map)
        if source.match?(/include\s+Wisper/)
          source.scan(/\b(?:publish|broadcast)\s+:(\w+)/) do |m|
            register_publisher(event_map, m[0], file_path, :wisper)
          end
        end

        # `.on(:sym)` is far too common a shape to treat as evidence on its own:
        # `socket.on(:message)`, `emitter.on(:close)`, and every other
        # callback-registration API in the ecosystem match it, each minting a
        # phantom event unit and its edges. Publishers were already gated on
        # Wisper context in the file; subscribers were not. Require the file to
        # mention Wisper somewhere before believing a bare `.on`.
        return unless wisper_context?(source)

        source.scan(/\.on\s*\(\s*:(\w+)/) do |m|
          register_subscriber(event_map, m[0], file_path, :wisper)
        end
      end

      # Does this file give any indication it is using Wisper?
      #
      # Deliberately broader than the publisher gate's `include Wisper` —
      # subscribers commonly live in files that reference Wisper without
      # including it (`Wisper.subscribe(listener)`, `extend
      # Wisper::Publisher`, a global-listener initializer).
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def wisper_context?(source)
        source.match?(/\bWisper\b/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Event Map Mutation
      # ──────────────────────────────────────────────────────────────────────

      # Register a publisher for an event name.
      #
      # @param event_map [Hash] Mutable event map
      # @param event_name [String] Event name
      # @param file_path [String] Publisher file path
      # @param pattern [Symbol] :active_support or :wisper
      # @return [void]
      def register_publisher(event_map, event_name, file_path, pattern)
        entry = event_map[event_name] ||= { publishers: [], subscribers: [], pattern: pattern }
        entry[:publishers] << file_path unless entry[:publishers].include?(file_path)
      end

      # Register a subscriber for an event name.
      #
      # @param event_map [Hash] Mutable event map
      # @param event_name [String] Event name
      # @param file_path [String] Subscriber file path
      # @param pattern [Symbol] :active_support or :wisper
      # @return [void]
      def register_subscriber(event_map, event_name, file_path, pattern)
        entry = event_map[event_name] ||= { publishers: [], subscribers: [], pattern: pattern }
        entry[:subscribers] << file_path unless entry[:subscribers].include?(file_path)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Unit Construction
      # ──────────────────────────────────────────────────────────────────────

      # Build an ExtractedUnit from accumulated event data.
      #
      # Returns nil if the event has neither publishers nor subscribers (no-op).
      #
      # @param event_name [String] Event name (used as the unit identifier)
      # @param data [Hash] Accumulated publishers/subscribers/pattern
      # @return [ExtractedUnit, nil]
      def build_unit(event_name, data)
        return nil if data[:publishers].empty? && data[:subscribers].empty?

        file_path = data[:publishers].first || data[:subscribers].first
        all_paths = (data[:publishers] + data[:subscribers]).uniq
        combined_source = load_source_files(all_paths)

        unit = ExtractedUnit.new(
          type: :event,
          identifier: event_name,
          file_path: file_path
        )

        unit.source_code = build_source_annotation(event_name, data)
        unit.metadata = {
          event_name: event_name,
          publishers: data[:publishers],
          subscribers: data[:subscribers],
          pattern: data[:pattern],
          publisher_count: data[:publishers].size,
          subscriber_count: data[:subscribers].size
        }
        unit.dependencies = build_dependencies(combined_source)
        unit
      end

      # Load source from multiple files for dependency scanning.
      #
      # Silently skips files that cannot be read.
      #
      # @param file_paths [Array<String>] File paths to read
      # @return [String] Combined source
      def load_source_files(file_paths)
        file_paths.filter_map { |path| cached_source(path) }.join("\n")
      end

      # One read per distinct path per extractor instance (audit P2).
      #
      # Pass 2 ({#build_unit}) recombines the same publisher/subscriber files
      # for every event that references them, so a widely-shared file was
      # re-read once per event on top of the pass-1 {#scan_file} read. The
      # bytes cannot change mid-run, so the first read answers the rest.
      #
      # A failed read is memoized as nil, matching the per-event skip it
      # produced before; the output is identical either way.
      #
      # @param path [String] File path
      # @return [String, nil] File contents, or nil when unreadable
      def cached_source(path)
        cache = (@source_files ||= {})
        return cache[path] if cache.key?(path)

        cache[path] = begin
          File.read(path)
        rescue StandardError
          nil
        end
      end

      # Build annotated source annotation for the event unit.
      #
      # @param event_name [String] Event name
      # @param data [Hash] Event data with publishers and subscribers
      # @return [String]
      def build_source_annotation(event_name, data)
        lines = ["# Event: #{event_name} (#{data[:pattern]})"]
        lines << "# Publishers: #{data[:publishers].join(', ')}" if data[:publishers].any?
        lines << "# Subscribers: #{data[:subscribers].join(', ')}" if data[:subscribers].any?
        lines.join("\n")
      end

      # Build dependencies by scanning combined source of publisher/subscriber files.
      #
      # @param combined_source [String] Combined source from all related files
      # @return [Array<Hash>]
      def build_dependencies(combined_source)
        deps = scan_common_dependencies(combined_source)
        consolidate_dependencies(deps)
      end
    end
  end
end
