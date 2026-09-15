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

        # Index traces by class_name + method_name
        grouped = group_traces(trace_data)

        units.each do |unit|
          class_name, method_name = parse_identifier(unit.identifier)
          next unless class_name && method_name

          key = "#{class_name}##{method_name}"
          next unless grouped.key?(key)

          traces = grouped[key]

          calls = traces.select { |t| fetch_key(t, :event) == 'call' }
          returns = traces.select { |t| fetch_key(t, :event) == 'return' }

          callers = calls.filter_map do |t|
            caller_class = fetch_key(t, :caller_class)
            caller_method = fetch_key(t, :caller_method)
            next unless caller_class

            { 'caller_class' => caller_class, 'caller_method' => caller_method }
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

            key = "#{class_name}##{method_name}"
            grouped[key] << trace
          end
          grouped
        end

        def parse_identifier(identifier)
          # Handle both "Class#method" and "Class.method" formats
          if identifier.include?('#')
            identifier.split('#', 2)
          elsif identifier.include?('.')
            identifier.split('.', 2)
          end
        end

        # Preserve event owner naming here; method-kind identity is a separate
        # concern. Stack entries reuse recorded calls rather than inspecting a
        # callee binding or guessing an interpreter-specific backtrace offset.
        def event_identity(tp)
          { class_name: tp.defined_class&.name || tp.defined_class.to_s,
            method_name: tp.method_id.to_s }
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
          { caller_class: frame && frame[:class_name], caller_method: frame && frame[:method_name] }
        end

        # Ruby emits :return during exceptional and nonlocal unwinds too. A
        # return whose call predates recording has no known caller; discard an
        # inconsistent stack instead of inventing an edge from unrelated frames.
        def returning_caller(identity, stack)
          frame = stack.pop
          if frame && identity.all? { |key, value| frame[key] == value }
            { caller_class: frame[:caller_class], caller_method: frame[:caller_method] }
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
