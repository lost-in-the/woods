# frozen_string_literal: true

require 'prism'

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'

module Woods
  module Extractors
    # EventExtractor discovers event publishing and subscribing patterns across the app.
    #
    # Scans +**/*.rb+ under each +Woods.configuration.event_paths+ root
    # (default +app+) for two event system conventions:
    # - ActiveSupport::Notifications: +instrument+ (publish) and +subscribe+ (consume)
    # - Wisper: +publish+/+broadcast+ (publish) and +on(:event_name)+ (subscribe)
    #
    # Applications with their own event wrapper add patterns through
    # +Woods.configuration.event_patterns+; see {Woods::Configuration#event_patterns=}.
    # Their +system+ label is recorded in metadata and never changes the identifier.
    # A configured match also records event identity detail: a +(?<scope>...)+
    # capture and the matched call's +scope:+ literal land in +metadata[:scopes]+,
    # its +event:+ literal in +metadata[:sub_events]+.
    #
    # Uses a two-pass approach:
    # 1. Scan all files, collecting publishers and subscribers per event name
    # 2. Merge by event name → one ExtractedUnit per unique event
    #
    # An event depends on the class or module that owns each publisher file
    # (+via: :published_by+) and each subscriber file (+via: :subscribed_by+),
    # so +dependents+ of an emitting class reaches its events.
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

      # Default scan roots; +Woods.configuration.event_paths+ replaces them.
      APP_DIRECTORIES = %w[app].freeze

      # Keyword arguments of a configured call recorded as event identity,
      # mapped to the metadata list each one feeds.
      IDENTITY_KEYWORDS = { 'scope' => :scopes, 'event' => :sub_events }.freeze

      def initialize
        roots = Woods.configuration&.event_paths || APP_DIRECTORIES
        @directories = roots.map { |d| Rails.root.join(d) }.select(&:directory?)
        @configured_patterns = Woods.configuration&.event_patterns || []
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
          SourceInputs::ConsumerErrors.log(self, "Failed to scan #{file_path} for events: file unreadable")
          return
        end

        scan_active_support_notifications(source, file_path, event_map)
        scan_wisper_patterns(source, file_path, event_map)
        scan_configured_patterns(source, file_path, event_map)
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to scan #{file_path} for events: #{e.message}")
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
          # `\s*\(?\s*` accepts both call styles. Requiring whitespace before
          # the symbol missed `broadcast(:order_created, order)` — Wisper's
          # README-canonical form — so no publisher was registered and, with
          # no subscriber naming the event either, the event unit did not
          # exist at all (EXTB-3). The AS::Notifications and `.on(` scans
          # already accept parens.
          source.scan(/\b(?:publish|broadcast)\s*\(?\s*:(\w+)/) do |m|
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

      # Scan for the application's own event APIs from +event_patterns+.
      #
      # The event name is the +(?<name>...)+ capture when the pattern has one,
      # else the first capture group. A match whose name capture did not
      # participate names no event and is skipped.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] File path
      # @param event_map [Hash] Mutable event map
      # @return [void]
      def scan_configured_patterns(source, file_path, event_map)
        tree = nil
        @configured_patterns.each do |entry|
          named = entry[:pattern].names.include?('name')
          source.scan(entry[:pattern]) do
            match = Regexp.last_match
            event_name = named ? match[:name] : match[1]
            next if event_name.nil? || event_name.empty?

            if entry[:role] == :publisher
              register_publisher(event_map, event_name, file_path, entry[:system])
            else
              register_subscriber(event_map, event_name, file_path, entry[:system])
            end
            tree ||= Prism.parse(source)
            record_identity(event_map[event_name], match, tree, source)
          end
        end
      end

      # Record a match's +(?<scope>...)+ capture and the matched call's
      # +scope:+ / +event:+ literals on the event entry, first seen first.
      #
      # @param entry [Hash] The event map entry
      # @param match [MatchData] A configured pattern match
      # @param tree [Prism::ParseResult] The file's parse result
      # @param source [String] Ruby source code
      # @return [void]
      def record_identity(entry, match, tree, source)
        values = Hash.new { |hash, key| hash[key] = [] }
        values[:scopes] << match[:scope] if match.names.include?('scope')
        call_keyword_literals(tree, match, source).each { |key, value| values[IDENTITY_KEYWORDS[key]] << value }

        values.each do |list, found|
          found.each { |value| entry[list] << value unless value.nil? || value.empty? || entry[list].include?(value) }
        end
      end

      # String or symbol literals passed as +scope:+ / +event:+ keywords to
      # the innermost call enclosing the match's name capture. Keywords of a
      # nested call and non-literal values are ignored.
      #
      # @param tree [Prism::ParseResult] The file's parse result
      # @param match [MatchData] A configured pattern match
      # @param source [String] Ruby source code
      # @return [Array<Array(String, String)>] keyword name and literal value pairs
      def call_keyword_literals(tree, match, source)
        return [] unless tree.success?

        name_group = match.names.include?('name') ? :name : 1
        from = source[0, match.begin(name_group)].bytesize
        to = source[0, match.end(0)].bytesize
        call = innermost_call(tree.value, from, to)
        keywords = call&.arguments&.arguments&.grep(Prism::KeywordHashNode)&.first
        return [] unless keywords

        keywords.elements.filter_map do |assoc|
          next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
          next unless IDENTITY_KEYWORDS.key?(assoc.key.unescaped)
          next unless assoc.value.is_a?(Prism::StringNode) || assoc.value.is_a?(Prism::SymbolNode)

          [assoc.key.unescaped, assoc.value.unescaped]
        end
      end

      # The deepest call node whose source span covers the byte range.
      #
      # @param root [Prism::Node] Program node
      # @param from [Integer] Start byte offset
      # @param to [Integer] End byte offset
      # @return [Prism::CallNode, nil]
      def innermost_call(root, from, to)
        found = nil
        stack = [root]
        while (node = stack.pop)
          location = node.location
          next unless location.start_offset <= from && to <= location.end_offset

          found = node if node.is_a?(Prism::CallNode)
          stack.concat(node.compact_child_nodes)
        end
        found
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
      # @param pattern [Symbol] :active_support, :wisper, or a configured system label
      # @return [void]
      def register_publisher(event_map, event_name, file_path, pattern)
        entry = event_entry(event_map, event_name, pattern)
        entry[:publishers] << file_path unless entry[:publishers].include?(file_path)
      end

      # Register a subscriber for an event name.
      #
      # @param event_map [Hash] Mutable event map
      # @param event_name [String] Event name
      # @param file_path [String] Subscriber file path
      # @param pattern [Symbol] :active_support, :wisper, or a configured system label
      # @return [void]
      def register_subscriber(event_map, event_name, file_path, pattern)
        entry = event_entry(event_map, event_name, pattern)
        entry[:subscribers] << file_path unless entry[:subscribers].include?(file_path)
      end

      # Find or create the map entry for an event, recording +pattern+ among
      # the systems that used the name. The first system seen stays +:pattern+.
      #
      # @param event_map [Hash] Mutable event map
      # @param event_name [String] Event name
      # @param pattern [Symbol] System that matched
      # @return [Hash] The entry
      def event_entry(event_map, event_name, pattern)
        entry = event_map[event_name] ||= { publishers: [], subscribers: [], pattern: pattern, systems: [],
                                            scopes: [], sub_events: [] }
        entry[:systems] << pattern unless entry[:systems].include?(pattern)
        entry
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
        dependencies = build_dependencies(data)

        # Keep absolute paths for source reads; emitted paths must not make
        # metadata or annotation hashes depend on the checkout directory.
        prefix = File.join(Rails.root.to_s, '')
        data = data.merge(
          publishers: data[:publishers].map { |path| path.delete_prefix(prefix) },
          subscribers: data[:subscribers].map { |path| path.delete_prefix(prefix) }
        )

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
        # Only when configured, so an app that sets nothing keeps byte-identical units.
        if @configured_patterns.any?
          unit.metadata[:systems] = data[:systems]
          unit.metadata[:scopes] = data[:scopes]
          unit.metadata[:sub_events] = data[:sub_events]
        end
        unit.dependencies = dependencies
        unit
      end

      # One read per distinct path per extractor instance (audit P2).
      #
      # Pass 2 ({#build_unit}) names the owner of the same publisher/subscriber
      # files for every event that references them, so a widely-shared file
      # was re-read once per event on top of the pass-1 {#scan_file} read. The
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

      # One edge per publisher file, then one per subscriber file, to the
      # class or module that file is named for. A file that declares neither
      # yields no edge.
      #
      # @param data [Hash] Accumulated publishers/subscribers (absolute paths)
      # @return [Array<Hash>]
      def build_dependencies(data)
        edges = data[:publishers].filter_map { |path| owner_edge(path, :published_by) } +
                data[:subscribers].filter_map { |path| owner_edge(path, :subscribed_by) }
        edges.uniq { |edge| [edge[:target], edge[:via]] }
      end

      # @param path [String] Absolute publisher or subscriber path
      # @param via [Symbol] :published_by or :subscribed_by
      # @return [Hash, nil]
      def owner_edge(path, via)
        owner = owner_name(path)
        owner && { type: :class, target: owner, via: via }
      end

      # The constant a file is named for, as the extractor that owns the file
      # would name it: the Zeitwerk-governed constant first, then the first
      # class, then the primary module.
      #
      # @param path [String] Absolute file path
      # @return [String, nil]
      def owner_name(path)
        source = cached_source(path)
        return nil unless source

        governed_class_name(path, source) || qualified_first_class_name(source) || qualified_outer_module_name(source)
      end
    end
  end
end
