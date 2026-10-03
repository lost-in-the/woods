# frozen_string_literal: true

require 'json'

module Woods
  module Storage
    # The searchable text of a stored metadata record, as the
    # {MetadataStore::Interface#search} contract defines it: literal
    # substring matching over JSON spellings. Shared by the in-memory
    # adapter and the read-only views over its records so both answer a
    # search identically.
    module SearchText
      module_function

      # The searchable text for one field value: strings come back raw,
      # structured values as JSON text, Booleans as true/false, and numbers
      # as their decimal form. A Ruby +Hash#to_s+ haystack used to leak
      # `=>` and `:sym` syntax that no JSON document contains (STO-8).
      #
      # @param value [Object] the stored field value
      # @return [String, nil] nil for a missing field, which never matches
      def field(value)
        case value
        when nil then nil
        when String then value
        when Hash, Array then JSON.generate(value)
        else value.to_s
        end
      end

      # The whole-record haystack: the record's JSON text, downcased once.
      #
      # @param record [Hash] a stored record without bookkeeping columns
      # @return [String]
      def record(record)
        JSON.generate(record).downcase
      end
    end
  end
end
