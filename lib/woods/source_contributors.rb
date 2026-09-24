# frozen_string_literal: true

require_relative 'source_contributor_validation'

module Woods
  # Provenance for a published unit assembled from several original files.
  # Byte ranges are half-open and exclude every generated header/separator.
  module SourceContributors
    Invalid = SourceContributorValidation::Invalid

    VERSION = 1

    module_function

    # @param unit [ExtractedUnit, Hash]
    # @return [Array<Hash>] validated, string-keyed contributor records
    def records(unit)
      metadata = field(unit, :metadata) || {}
      raw = field(metadata, :source_contributors)
      return [] if raw.nil?

      SourceContributorValidation.validate!(raw, type: field(unit, :type),
                                                 version: field(metadata, :source_contributors_version),
                                                 source: field(unit, :source_code))
    end

    # @param unit [ExtractedUnit, Hash]
    # @return [Array<String>] every physical source, or the legacy primary path
    def paths(unit)
      contributors = records(unit)
      contributors.empty? ? Array(field(unit, :file_path)) : contributors.map { |record| record.fetch('file_path') }
    end

    # @param unit [ExtractedUnit, Hash]
    # @return [Boolean]
    def multiple?(unit)
      !records(unit).empty?
    end

    # @param unit [ExtractedUnit, Hash]
    # @param start_byte [Integer] inclusive published byte offset
    # @param end_byte [Integer] exclusive published byte offset
    # @return [Hash, nil] physical coordinates only for an exact original fragment
    def physical_span(unit, start_byte:, end_byte:)
      return unless valid_span?(start_byte, end_byte)

      record = records(unit).find do |fragment|
        start_byte >= fragment['published_start_byte'] && end_byte <= fragment['published_end_byte']
      end
      return unless record

      source = field(unit, :source_code)
      return unless source.is_a?(String)

      first = record['source_start_line'] + source.byteslice(record['published_start_byte']...start_byte).count("\n")
      { file_path: record['file_path'], source_sha256: record['source_sha256'], start_line: first,
        end_line: first + source.byteslice(start_byte...end_byte).delete_suffix("\n").count("\n") }
    end

    def valid_span?(first, last)
      first.is_a?(Integer) && last.is_a?(Integer) && last > first
    end
    private_class_method :valid_span?

    # @param unit [ExtractedUnit, Hash]
    # @return [String] explicit primary/contributor label, or legacy file label
    def label(unit)
      return "File: #{field(unit, :file_path)}" unless multiple?(unit)

      "Primary file: #{field(unit, :file_path)}\nContributing files: #{paths(unit).join(', ')}"
    end

    # @param unit [ExtractedUnit, Hash]
    # @return [Hash] additive contributor evidence for response renderers
    def attribution(unit)
      multiple?(unit) ? { source_contributors: records(unit) } : {}
    end

    # @param unit [ExtractedUnit, Hash]
    # @param resolver [Object] package_for(path) collaborator
    # @return [String, nil] unanimous package ownership, or nil
    def annotate_package(unit, resolver)
      contributors = records(unit)
      return resolver.package_for(field(unit, :file_path)) if contributors.empty?

      packages = contributors.map do |record|
        package = resolver.package_for(record['file_path'])
        package ? record['package'] = package : record.delete('package')
        package
      end
      packages.first if packages.uniq.one?
    end

    # @param unit [ExtractedUnit, Hash]
    # @param data [Hash] Git facts keyed by application-relative source path
    # @return [void]
    def annotate_git(unit, data)
      records(unit).each do |record|
        record.delete('git')
        record['git'] = data[record['file_path']] if data[record['file_path']]
      end
      metadata = field(unit, :metadata)
      metadata.delete(:git)
      metadata.delete('git')
    end

    # @param value [Object, Hash]
    # @param key [Symbol]
    # @return [Object]
    def field(value, key)
      return value[key] || value[key.to_s] if value.is_a?(Hash)

      value.public_send(key) if value.respond_to?(key)
    end
  end
end
