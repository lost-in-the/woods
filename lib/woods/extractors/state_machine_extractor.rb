# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # StateMachineExtractor scans app/models for state machine DSL definitions.
    #
    # Supports three state machine gems:
    # - AASM: files that include AASM with +aasm do...end+ blocks
    # - Statesman: files that include Statesman::Machine with state/transition calls
    # - state_machines: files using the +state_machine :attr do...end+ DSL
    #
    # Produces one ExtractedUnit per state machine definition found.
    # A single model file can produce multiple units (e.g., two state_machine blocks).
    #
    # @example
    #   extractor = StateMachineExtractor.new
    #   units = extractor.extract_all
    #   order_sm = units.find { |u| u.identifier == "Order::aasm" }
    #   order_sm.metadata[:states]  # => ["pending", "processing", "completed"]
    #   order_sm.metadata[:gem_detected]  # => "aasm"
    #
    class StateMachineExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      MODEL_DIRECTORIES = %w[app/models].freeze

      def initialize
        @directories = MODEL_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
      end

      # Extract all state machine definitions from model files.
      #
      # @return [Array<ExtractedUnit>] List of state machine units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].flat_map { |file| extract_model_file(file) }
        end
      end

      # Extract state machine definitions from a single model file.
      #
      # Returns an Array because one model file may contain multiple state machine
      # definitions (e.g., multiple +state_machine+ blocks for different attributes).
      #
      # @param file_path [String] Path to the model file
      # @return [Array<ExtractedUnit>] List of state machine units (empty if none detected)
      def extract_model_file(file_path)
        source = File.read(file_path)
        class_name = detect_class_name(source, file_path)

        units = []
        units.concat(extract_aasm_units(source, class_name, file_path))
        units.concat(extract_statesman_units(source, class_name, file_path))
        units.concat(extract_state_machines_units(source, class_name, file_path))
        units
      rescue StandardError => e
        Rails.logger.error("Failed to extract state machines from #{file_path}: #{e.message}")
        []
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Detect class name from source or derive it from the file path.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] File path
      # @return [String] Class name
      def detect_class_name(source, file_path)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^app/models/}, '').sub('.rb', '').camelize
      end

      # ──────────────────────────────────────────────────────────────────────
      # AASM
      # ──────────────────────────────────────────────────────────────────────

      # Extract AASM state machine units from source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_aasm_units(source, class_name, file_path)
        return [] unless source.match?(/include\s+AASM/)

        states = source.scan(/^\s*state\s+:(\w+)/).flatten
        initial_state = parse_initial_state_aasm(source)
        events = parse_events_from_source(source, /\Aevent\s+:(\w+)/)
        callbacks = parse_state_machine_callbacks(source)

        [build_unit(
          identifier: "#{class_name}::aasm",
          class_name: class_name,
          file_path: file_path,
          source: source,
          gem_detected: 'aasm',
          states: states,
          events: events,
          transitions: events.flat_map { |e| e[:transitions] },
          initial_state: initial_state,
          callbacks: callbacks
        )]
      end

      # Parse initial state from AASM source.
      #
      # Handles both:
      #   state :pending, initial: true
      #   aasm initial: :pending do
      #
      # @param source [String] Ruby source code
      # @return [String, nil]
      def parse_initial_state_aasm(source)
        match = source.match(/state\s+:(\w+)[^#\n]*initial:\s*true/)
        return match[1] if match

        match = source.match(/aasm\b[^#\n]*initial:\s*:(\w+)/)
        match ? match[1] : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Statesman
      # ──────────────────────────────────────────────────────────────────────

      # Extract Statesman state machine units from source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_statesman_units(source, class_name, file_path)
        return [] unless source.match?(/include\s+Statesman::Machine/)

        states = source.scan(/^\s*state\s+:(\w+)/).flatten
        initial_state = source.match(/state\s+:(\w+)[^#\n]*,\s*initial:\s*true/)&.[](1)
        transitions = parse_statesman_transitions(source)
        callbacks = parse_state_machine_callbacks(source)

        [build_unit(
          identifier: "#{class_name}::statesman",
          class_name: class_name,
          file_path: file_path,
          source: source,
          gem_detected: 'statesman',
          states: states,
          events: [],
          transitions: transitions,
          initial_state: initial_state,
          callbacks: callbacks
        )]
      end

      # Parse transitions from Statesman source.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Transitions with :from, :to, :guard keys
      def parse_statesman_transitions(source)
        source.scan(/transition\s+from:\s*:(\w+)\s*,\s*to:\s*:(\w+)/).map do |from, to|
          { from: from, to: to, guard: nil }
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # state_machines gem
      # ──────────────────────────────────────────────────────────────────────

      # Extract state_machines gem state machine units from source.
      #
      # Handles multiple state_machine blocks for different attributes.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @return [Array<ExtractedUnit>]
      def extract_state_machines_units(source, class_name, file_path)
        return [] unless source.match?(/\bstate_machine\b/)

        units = []
        source.scan(/state_machine\s+:(\w+)/) do |match|
          attr_name = match[0]
          block = extract_block_for_state_machine(source, attr_name)
          states = block.scan(/^\s*state\s+:(\w+)/).flatten
          events = parse_events_from_source(block, /\Aevent\s+:(\w+)/)
          initial_state = source.match(/state_machine\s+:#{Regexp.escape(attr_name)}[^#\n]*initial:\s*:(\w+)/)&.[](1)
          callbacks = parse_state_machine_callbacks(block)

          units << build_unit(
            identifier: "#{class_name}::state_machine_#{attr_name}",
            class_name: class_name,
            file_path: file_path,
            source: source,
            gem_detected: 'state_machines',
            states: states,
            events: events,
            transitions: events.flat_map { |e| e[:transitions] },
            initial_state: initial_state,
            callbacks: callbacks
          )
        end

        units
      end

      # Extract the block body for a specific state_machine attribute.
      #
      # Uses depth tracking (do/end balance) to find the block boundaries.
      #
      # @param source [String] Ruby source code
      # @param attr_name [String] Attribute name (e.g., "status")
      # @return [String] Block body source
      def extract_block_for_state_machine(source, attr_name)
        lines = source.lines
        result = []
        depth = 0
        capturing = false

        lines.each do |line|
          stripped = line.strip

          unless capturing
            if stripped.match?(/\Astate_machine\s+:#{Regexp.escape(attr_name)}.*\bdo\b/)
              capturing = true
              depth = 1
            end
            next
          end

          depth += 1 if block_opener?(stripped)
          depth -= 1 if stripped == 'end'
          break if depth <= 0

          result << line
        end

        result.join
      end

      # ──────────────────────────────────────────────────────────────────────
      # Shared Parsing Helpers
      # ──────────────────────────────────────────────────────────────────────

      # Parse state machine callbacks (before_transition, after_transition, etc.).
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Callback descriptions
      def parse_state_machine_callbacks(source)
        callbacks = []
        source.scan(/(before_transition|after_transition|around_transition|after_failure)\s+(.+?)(?=\n)/) do |cb, args|
          callbacks << "#{cb} #{args.strip}"
        end
        callbacks
      end

      # Parse events from source using a line-by-line depth tracker.
      #
      # Correctly handles nested blocks (e.g., guard lambdas) within event blocks.
      # Only processes lines after detecting +event :name do+, and closes the event
      # when the matching +end+ is found.
      #
      # @param source [String] Source code to parse
      # @param event_pattern [Regexp] Pattern to match event declaration (must capture event name in group 1)
      # @return [Array<Hash>] Events with :name and :transitions keys
      def parse_events_from_source(source, event_pattern)
        events = []
        current_event = nil
        depth = 0

        source.each_line do |line|
          stripped = line.strip
          next if stripped.start_with?('#')

          if depth.zero? && (m = stripped.match(event_pattern))
            current_event = { name: m[1], transitions: [] }
            depth = 1 if stripped.include?(' do') || stripped.end_with?('do')
            next
          end

          next unless current_event

          if (t = parse_transition_line(stripped))
            current_event[:transitions] << t
          end

          if stripped.match?(/\bdo\b/) && depth.positive?
            depth += 1
          elsif stripped == 'end'
            depth -= 1
            if depth.zero?
              events << current_event
              current_event = nil
            end
          end
        end

        events
      end

      # Parse a single transition line into a structured hash.
      #
      # Handles two styles:
      # - AASM/Statesman: +transitions from: :a, to: :b, guard: :method+
      # - state_machines: +transition pending: :active+
      #
      # @param line [String] Stripped source line
      # @return [Hash, nil] Transition hash with :from, :to, :guard, or nil if not a transition
      def parse_transition_line(line)
        if (m = line.match(/transitions?\s+from:\s*:(\w+)\s*,\s*to:\s*:(\w+)/))
          guard = line.match(/guard:\s*:?(\w+[?!]?)/)&.[](1)
          return { from: m[1], to: m[2], guard: guard }
        end

        if (m = line.match(/\Atransition\s+(\w+):\s*:(\w+)/))
          return { from: m[1], to: m[2], guard: nil }
        end

        nil
      end

      # Check if a line opens a new block.
      #
      # Mirrors the implementation in RakeTaskExtractor to correctly handle
      # trailing +if+/+unless+ modifiers vs standalone block openers.
      #
      # @param stripped [String] Stripped line content
      # @return [Boolean]
      def block_opener?(stripped)
        return true if stripped.match?(/\b(do|def|case|begin|class|module|while|until|for)\b.*(?<!\bend)\s*$/)

        stripped.match?(/\A(if|unless)\b/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Unit Construction
      # ──────────────────────────────────────────────────────────────────────

      # Build an ExtractedUnit from parsed state machine data.
      #
      # @param identifier [String] Unit identifier (e.g., "Order::aasm")
      # @param class_name [String] Model class name
      # @param file_path [String] File path
      # @param source [String] Model source code
      # @param gem_detected [String] Which state machine gem was detected
      # @param states [Array<String>] Detected state names
      # @param events [Array<Hash>] Detected events with transitions
      # @param transitions [Array<Hash>] Flat list of all transitions
      # @param initial_state [String, nil] Initial state name
      # @param callbacks [Array<String>] Detected callbacks
      # @return [ExtractedUnit]
      def build_unit(identifier:, class_name:, file_path:, source:, gem_detected:,
                     states:, events:, transitions:, initial_state:, callbacks:)
        unit = ExtractedUnit.new(
          type: :state_machine,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = "# State machine (#{gem_detected}) for #{class_name}\n#{source}"
        unit.metadata = {
          gem_detected: gem_detected,
          states: states,
          events: events,
          transitions: transitions,
          initial_state: initial_state,
          callbacks: callbacks,
          model_name: class_name
        }
        unit.dependencies = build_dependencies(class_name, source)
        unit
      end

      # Build dependencies for a state machine unit.
      #
      # Always includes a reference to the host model. Also scans source for
      # service and job references that may be invoked in callbacks.
      #
      # @param class_name [String] Model class name
      # @param source [String] Ruby source code
      # @return [Array<Hash>]
      def build_dependencies(class_name, source)
        deps = [{ type: :model, target: class_name, via: :state_machine }]
        deps.concat(scan_service_dependencies(source, via: :state_machine_callback))
        deps.concat(scan_job_dependencies(source, via: :state_machine_callback))
        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
