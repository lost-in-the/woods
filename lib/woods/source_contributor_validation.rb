# frozen_string_literal: true

require 'digest'

module Woods
  # Checks the versioned contributor boundary before consumers use its paths or coordinates.
  module SourceContributorValidation
    class Invalid < ArgumentError; end

    RANGE_KEYS = %w[source_start_line source_end_line published_start_byte published_end_byte
                    published_start_line published_end_line].freeze

    module_function

    def validate!(records, type:, version:, source:)
      unless type.to_s == 'lib' && version == 1 && records.is_a?(Array) && records.size.between?(2, 100_000)
        raise Invalid, 'Invalid library contributor version or records'
      end

      validate_records!(records)
      records.each { |record| validate_source!(source, record) } if source.is_a?(String)
      records
    end

    def validate_records!(records)
      previous = 0
      paths = records.map do |record|
        unless valid_record?(record) && valid_ranges?(record, previous)
          raise Invalid, 'Invalid library contributor path or range'
        end

        previous = record.fetch('published_end_byte')
        record.fetch('file_path')
      end
      raise Invalid, 'Unordered or duplicate library contributor path' unless paths.uniq.sort == paths
    end

    def valid_record?(record)
      record.is_a?(Hash) && record.keys.all?(String) && valid_path?(record['file_path']) &&
        valid_hash?(record['source_sha256']) &&
        record['facts'].is_a?(Hash) && RANGE_KEYS.all? { |key| record[key].is_a?(Integer) }
    end

    def valid_hash?(hash)
      hash.is_a?(String) && hash.match?(/\A[0-9a-f]{64}\z/)
    end

    def valid_ranges?(record, previous)
      record['source_start_line'] == 1 && record['source_end_line'].positive? &&
        record['published_start_byte'] >= previous && record['published_end_byte'] > record['published_start_byte'] &&
        record['published_start_line'].positive? && record['published_end_line'] >= record['published_start_line']
    end

    def valid_path?(path)
      path.is_a?(String) && path.start_with?('lib/') && path.end_with?('.rb') && !path.include?("\0") &&
        !path.include?('\\') && path.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
    end

    def validate_source!(source, record)
      raise Invalid, 'Contributor range exceeds published source' if record['published_end_byte'] > source.bytesize

      fragment = source.byteslice(record['published_start_byte']...record['published_end_byte'])
      first = source.byteslice(0...record['published_start_byte']).count("\n") + 1
      return if valid_fragment?(fragment, first, record)

      raise Invalid, 'Library contributor bytes do not match published provenance'
    end

    def valid_fragment?(fragment, first, record)
      Digest::SHA256.hexdigest(fragment) == record['source_sha256'] &&
        fragment.lines.size == record['source_end_line'] && first == record['published_start_line'] &&
        first + fragment.lines.size - 1 == record['published_end_line']
    end
    private_class_method :validate_records!, :valid_record?, :valid_hash?, :valid_ranges?, :valid_path?,
                         :validate_source!,
                         :valid_fragment?
  end
end
