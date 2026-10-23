# frozen_string_literal: true

module Woods
  module SourceReferences
    # Bounded syntactic selector evidence shared by both collectors and the cache.
    # A selector does not establish method existence, dispatch or definition owner.
    module Selector
      MAX_BYTES = 4096

      module_function

      # @param name [Symbol] selector supplied by a Ruby parser
      # @return [String, nil] UTF-8 evidence, absent when outside the supported bound
      def from(name)
        value = name.to_s.encode(Encoding::UTF_8)
        value if valid?(value)
      rescue EncodingError
        nil
      end

      # @param value [Object] candidate cache field
      # @return [Boolean] whether the field is supported selector evidence
      def valid?(value)
        value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
          value.bytesize.between?(1, MAX_BYTES) && !value.match?(/[[:cntrl:]]/)
      end
    end
  end
end
