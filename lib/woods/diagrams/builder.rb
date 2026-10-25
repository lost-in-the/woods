# frozen_string_literal: true

module Woods
  module Diagrams
    # What every kind shares: the request, the options it accepts, and the
    # {Result} it answers with, drawn or refused over its budget.
    class Builder
      # @param source [Source]
      # @param identifier [String]
      # @param type [String, nil]
      # @param depth [Integer] already checked against the kind's range
      # @param options [Hash] the kind's options
      def initialize(source, identifier:, type:, depth:, **options)
        unknown = options.keys.map(&:to_s) - self.class::OPTIONS
        raise InvalidRequest, "#{kind} takes no #{unknown.join(', ')}" if unknown.any?

        @source = source
        @identifier = identifier
        @type = type
        @depth = depth
        @options = options.transform_keys(&:to_s)
      end

      # @return [Result]
      def result
        prepare
        refusal = refusal_text
        Result.new(text: refusal ? nil : mermaid, refusal: refusal, generation: @source.generation,
                   details: { 'kind' => kind, 'identifier' => @identifier, 'type' => @type, 'depth' => @depth,
                              'budget' => budget, 'size' => size }.merge(extra_details).freeze)
      end

      private

      # @return [String] the kind's name
      def kind
        self.class::KIND
      end

      # Resolve the unit and validate the options; raises before anything is built.
      def prepare; end

      # @return [Hash] kind-specific facts for the result's details
      def extra_details
        {}
      end

      # @param types [Array<String>] the unit types this kind draws
      # @return [Hash] the published unit of the request's typed identity
      # @raise [UnitNotFound, InvalidRequest]
      def unit_of(types)
        type = @type || @source.type_of(@identifier)
        unit = type && @source.unit(@identifier, type: type)
        raise UnitNotFound, "No unit #{@identifier}#{" of type #{@type}" if @type} in this generation" unless unit
        unless types.include?(unit['type'].to_s)
          raise InvalidRequest, "A #{kind} diagram draws a #{types.join(' or ')}; #{@identifier} is a #{unit['type']}"
        end

        @type = unit['type'].to_s
        unit
      end

      # @param name [String]
      # @param allowed [Array<String>]
      # @param default [String]
      # @return [String]
      def choice(name, allowed, default)
        value = @options.fetch(name, default).to_s
        return value if allowed.include?(value)

        raise InvalidRequest, "#{name} must be one of #{allowed.join(', ')}; got #{value.inspect}"
      end

      # @param name [String]
      # @return [Array<String>, nil]
      def string_list(name)
        value = @options[name]
        return nil if value.nil?
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise InvalidRequest, "#{name} must be a list of names"
        end

        value
      end
    end
  end
end
