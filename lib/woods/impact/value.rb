# frozen_string_literal: true

require 'json'

module Woods
  module Impact
    # Canonical JSON values, detached from their inputs and recursively frozen.
    module Value
      # @param value [Object] JSON-compatible value with string keys
      # @return [Object] canonical immutable copy; array order is significant
      def self.copy(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key.dup.freeze, copy(value.fetch(key))] }.freeze
        when Array
          value.map { |item| copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      # @param value [Object] JSON-compatible value
      # @return [String] deterministic compact JSON
      def self.json(value)
        JSON.generate(copy(value))
      end
    end
  end
end
