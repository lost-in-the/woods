# frozen_string_literal: true

module Woods
  module Console
    # Normalizes integer inputs and enforces the bounds declared by a ToolSpec.
    module InputContract
      class ValidationError < StandardError; end

      DECIMAL_INTEGER = /\A-?(?:0|[1-9]\d*)\z/
      private_constant :DECIMAL_INTEGER

      module_function

      def normalize!(arguments, properties)
        properties.each do |property_name, definition|
          next unless definition[:type] == 'integer'

          key = argument_key(arguments, property_name)
          next unless key

          value = parse_integer(arguments[key], property_name)
          enforce_bounds!(value, property_name, definition)
          arguments[key] = value
        end

        arguments
      end

      # Reject a String value for any integer-typed property, without
      # attempting to parse it. Used ahead of {normalize!} on paths that skip
      # full JSON-Schema validation (e.g. an unregistered tool spec): without
      # this, a well-formed decimal string like `"15"` sails past
      # {parse_integer} untouched (it's valid input to that method) even
      # though the declared schema's `type: integer` would reject any String
      # outright — silently coercing input the public contract disallows.
      #
      # @param arguments [Hash] Mutated arguments hash (string or symbol keys)
      # @param properties [Hash] ToolSpec JSON Schema property definitions
      # @raise [ValidationError] when an integer-typed property holds a String
      def reject_string_typed_integers!(arguments, properties)
        properties.each do |property_name, definition|
          next unless definition[:type] == 'integer'

          key = argument_key(arguments, property_name)
          next unless key
          next unless arguments[key].is_a?(String)

          raise ValidationError, "#{property_name} must be an integer"
        end
      end

      def argument_key(arguments, property_name)
        return property_name if arguments.key?(property_name)

        string_name = property_name.to_s
        string_name if arguments.key?(string_name)
      end
      private_class_method :argument_key

      def parse_integer(value, property_name)
        return value if value.is_a?(Integer)
        return Integer(value, 10) if value.is_a?(String) && DECIMAL_INTEGER.match?(value)

        raise ValidationError, "#{property_name} must be an integer"
      end
      private_class_method :parse_integer

      def enforce_bounds!(value, property_name, definition)
        minimum = definition.fetch(:minimum)
        maximum = definition.fetch(:maximum)
        return if value.between?(minimum, maximum)

        raise ValidationError, "#{property_name} must be between #{minimum} and #{maximum}"
      end
      private_class_method :enforce_bounds!
    end
  end
end
