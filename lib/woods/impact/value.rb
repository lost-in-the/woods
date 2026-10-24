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

      # Whether two JSON values have the same {.json}, without building it.
      # `Hash#eql?` and `Array#eql?` compare members with `eql?`, so key
      # order is ignored while array order and the Integer/Float distinction
      # are not (`1` and `1.0` generate different JSON). The one pair whose
      # JSON differs but which compares the same is `-0.0` and `0.0`.
      #
      # @param left [Object] JSON-compatible value
      # @param right [Object] JSON-compatible value
      # @return [Boolean]
      def self.same?(left, right)
        left.eql?(right)
      end
    end
  end
end
