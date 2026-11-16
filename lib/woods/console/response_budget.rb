# frozen_string_literal: true

module Woods
  module Console
    # Bounds the materialized response before scanning/rendering and checks the
    # encoded tool result afterwards. This cannot bound database-driver or
    # custom-serializer allocations that occur before Woods receives a value.
    class ResponseBudget
      class Exceeded < StandardError; end

      DEFAULT_VALUE_BYTES = 64 * 1024
      DEFAULT_RESPONSE_BYTES = 4 * 1024 * 1024
      MAX_DEPTH = 100
      REFUSAL_CODE = 'response_budget_exceeded'

      attr_reader :value_bytes, :response_bytes

      # @param config [Woods::Configuration, nil] Captured once at construction.
      # @raise [ArgumentError] when either limit is not a positive Integer
      def initialize(config: (Woods.configuration if Woods.respond_to?(:configuration)))
        @value_bytes = setting(config, :console_max_value_bytes, DEFAULT_VALUE_BYTES)
        @response_bytes = setting(config, :console_max_response_bytes, DEFAULT_RESPONSE_BYTES)
      end

      # Walk without changing discriminators before the first redaction pass.
      # The depth and shape fence also refuses cycles without stack overflow.
      #
      # @param value [Object]
      # @raise [Exceeded]
      # @return [void]
      def verify_shape!(value)
        check_shape(value, [0], 0)
      end

      # @param value [Object] Already column/EAV-redacted result.
      # @raise [Exceeded]
      # @return [Object] Bounded copy, with whole-value omission markers.
      def apply(value)
        walk(value, [0], 0)
      end

      # @param encoded [String] Encoded JSON or encoded MCP tool result.
      # @raise [Exceeded]
      # @return [String]
      def check_encoded!(encoded)
        raise Exceeded if encoded.bytesize > response_bytes

        encoded
      end

      # Fixed-content refusal; never includes a source value or field name.
      # This small control response is exempt from the configured data budget.
      #
      # @return [String]
      def refusal
        "#{REFUSAL_CODE}: Console response exceeds #{response_bytes} bytes " \
          'or its safe shape limits. Narrow columns, limit or scope.'
      end

      private

      def setting(config, name, fallback)
        value = config.respond_to?(name) ? config.public_send(name) : fallback
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive integer"
      end

      def charge!(counter, bytes)
        counter[0] += bytes
        raise Exceeded if counter[0] > response_bytes
      end

      def check_shape(value, counter, depth)
        raise Exceeded if depth > MAX_DEPTH

        charge!(counter, 1)
        case value
        when Hash
          value.each do |key, child|
            charge!(counter, key.to_s.bytesize + 3)
            check_shape(child, counter, depth + 1)
          end
        when Array
          value.each { |child| check_shape(child, counter, depth + 1) }
        when String, Symbol
          charge!(counter, [value.to_s.bytesize, value_bytes].min)
        end
      end

      def walk(value, counter, depth)
        raise Exceeded if depth > MAX_DEPTH

        charge!(counter, 1)
        case value
        when Hash then walk_hash(value, counter, depth)
        when Array then value.map { |child| walk(child, counter, depth + 1) }
        when String, Symbol then bounded_value(value, counter)
        else value # Custom serialization is checked before parsing/scanning.
        end
      end

      def walk_hash(value, counter, depth)
        value.each_with_object({}) do |(key, child), result|
          key_text = key.to_s
          raise Exceeded if key_text.bytesize > value_bytes

          verify_headers!(child) if key_text == 'columns'
          charge!(counter, key_text.bytesize + 3)
          result[key] = walk(child, counter, depth + 1)
        end
      end

      def bounded_value(value, counter)
        text = value.to_s
        if text.bytesize > value_bytes
          charge!(counter, 100)
          omission
        else
          charge!(counter, text.bytesize + 2)
          value
        end
      end

      # An omission marker in a header would rename the column it describes.
      def verify_headers!(columns)
        return unless columns.is_a?(Array)

        raise Exceeded if columns.any? { |column| column.to_s.bytesize > value_bytes }
      end

      def omission
        { 'type' => 'value_omitted', 'reason' => 'max_value_bytes', 'limit_bytes' => value_bytes }
      end
    end
  end
end
