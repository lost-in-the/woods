# frozen_string_literal: true

require 'fiber'

require_relative '../extracted_unit'

module Woods
  module RubyAnalyzer
    # Enriches ExtractedUnit objects with runtime trace data.
    #
    # Two modes:
    # - Recording: wraps a block with TracePoint to capture method calls
    # - Merging: enriches existing units with previously collected trace data
    #
    # @example Recording
    #   trace_data = TraceEnricher.record { MyApp.run }
    #
    # @example Merging
    #   TraceEnricher.merge(units: units, trace_data: trace_data)
    #
    class TraceEnricher
      # Record method calls during block execution using TracePoint.
      #
      # Records the current thread only, with independent stacks for its fibers.
      # Caller fields identify the nearest observed Ruby method, not native or
      # block frames. Calls entered before recording have an unknown caller.
      #
      # @yield Block to trace
      # @return [Array<Hash>] Collected trace events
      # @raise [ArgumentError] if no block is given
      def self.record(&block)
        raise ArgumentError, 'block required' unless block

        traces = []
        stacks = Hash.new { |frames, fiber| frames[fiber] = [] }
        trace = TracePoint.new(:call, :return) do |tp|
          fiber = Fiber.current
          stack = stacks[fiber]
          traces << record_event(tp, stack)
          stacks.delete(fiber) if stack.empty?
        end

        trace.enable(target_thread: Thread.current, &block)
        traces
      end

      # Merge trace data into existing units.
      #
      # Mutates each matching unit's metadata by adding a :trace key with
      # call count, callers, and return types.
      #
      # @param units [Array<ExtractedUnit>] Units to enrich
      # @param trace_data [Array<Hash>] Trace events (from recording or JSON fixture)
      # @return [Array<ExtractedUnit>] The same units, now enriched
      def self.merge(units:, trace_data:)
        return units if trace_data.nil? || trace_data.empty?

        # Index by defining owner, method name, and instance/singleton kind.
        grouped = group_traces(trace_data)

        units.each do |unit|
          key = parse_identifier(unit.identifier)
          next unless grouped.key?(key)

          traces = grouped[key]

          calls = traces.select { |t| fetch_key(t, :event) == 'call' }
          returns = traces.select { |t| fetch_key(t, :event) == 'return' }

          callers = calls.filter_map do |t|
            caller_class = fetch_key(t, :caller_class)
            caller_method = fetch_key(t, :caller_method)
            next unless caller_class

            caller = { 'caller_class' => caller_class, 'caller_method' => caller_method }
            kind = fetch_key(t, :caller_method_kind)
            caller['caller_method_kind'] = kind.to_s if kind
            caller
          end

          return_types = returns.filter_map do |t|
            fetch_key(t, :return_class)
          end.uniq

          unit.metadata[:trace] = {
            call_count: calls.size,
            callers: callers,
            return_types: return_types
          }
        end
      end

      class << self
        private

        def fetch_key(hash, key)
          hash[key.to_s] || hash[key.to_sym]
        end

        def group_traces(trace_data)
          grouped = Hash.new { |h, k| h[k] = [] }
          trace_data.each do |trace|
            class_name = fetch_key(trace, :class_name)
            method_name = fetch_key(trace, :method_name)
            next unless class_name && method_name

            # Legacy recorder output with a named owner describes instance
            # methods. Never infer its kind from the units supplied to merge.
            kind = (fetch_key(trace, :method_kind) || 'instance').to_s
            next unless %w[instance singleton].include?(kind)
            next if class_name.start_with?('#<')

            grouped[[class_name, method_name, kind]] << trace
          end
          grouped
        end

        def parse_identifier(identifier)
          match = /\A(.+?)([#.])(.+)\z/.match(identifier)
          return unless match

          [match[1], match[3], match[2] == '#' ? 'instance' : 'singleton']
        end

        def event_identity(tp)
          owner = tp.defined_class
          singleton = owner&.singleton_class?
          name = singleton ? singleton_owner_name(owner, tp.self) : owner&.name
          { class_name: name, method_name: tp.method_id.to_s,
            method_kind: singleton ? 'singleton' : 'instance' }
        end

        # Ruby 3.0 has no Class#attached_object. Find the defining owner,
        # not just the receiver: Child.run may be defined on Parent's singleton
        # class. Singleton methods on individual objects have no named unit.
        def singleton_owner_name(owner, receiver)
          return unless receiver.is_a?(Module)

          receiver.ancestors.find { |ancestor| ancestor.singleton_class.equal?(owner) }&.name
        end

        def record_event(tp, stack)
          identity = event_identity(tp)
          caller = if tp.event == :call
                     caller_fields(stack.last)
                   else
                     returning_caller(identity, stack)
                   end
          event = identity.merge(
            event: tp.event.to_s, path: tp.path, line: tp.lineno,
            **caller, return_class: tp.event == :return ? safe_return_class(tp) : nil
          )
          stack << event if tp.event == :call
          event
        end

        def caller_fields(frame)
          frame = nil unless frame && frame[:class_name]
          { caller_class: frame && frame[:class_name], caller_method: frame && frame[:method_name],
            caller_method_kind: frame && frame[:method_kind] }
        end

        # Ruby emits :return during exceptional and nonlocal unwinds too. A
        # return whose call predates recording has no known caller; discard an
        # inconsistent stack instead of inventing an edge from unrelated frames.
        def returning_caller(identity, stack)
          frame = stack.pop
          if frame && identity.all? { |key, value| frame[key] == value }
            { caller_class: frame[:caller_class], caller_method: frame[:caller_method],
              caller_method_kind: frame[:caller_method_kind] }
          else
            stack.clear
            caller_fields(nil)
          end
        end

        def safe_return_class(tp)
          tp.return_value.class.name
        rescue StandardError
          nil
        end
      end
    end
  end
end
