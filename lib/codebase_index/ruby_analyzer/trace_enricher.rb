# frozen_string_literal: true

require_relative '../extracted_unit'

module CodebaseIndex
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
      # @yield Block to trace
      # @return [Array<Hash>] Collected trace events
      def self.record(&block)
        traces = []

        trace = TracePoint.new(:call, :return) do |tp|
          traces << {
            class_name: tp.defined_class&.name || tp.defined_class.to_s,
            method_name: tp.method_id.to_s,
            event: tp.event.to_s,
            path: tp.path,
            line: tp.lineno,
            caller_class: extract_caller_class(tp),
            caller_method: extract_caller_method(tp),
            return_class: tp.event == :return ? safe_return_class(tp) : nil
          }
        end

        trace.enable(&block)
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

        def extract_caller_class(tp)
          binding_obj = tp.binding
          receiver = binding_obj.receiver
          receiver.is_a?(Class) || receiver.is_a?(Module) ? receiver.name : receiver.class.name
        rescue StandardError
          nil
        end

        def extract_caller_method(_tp)
          # TracePoint doesn't directly expose caller method,
          # but we can get it from the call stack
          caller_locations(3, 1)&.first&.label
        rescue StandardError
          nil
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
