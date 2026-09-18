# frozen_string_literal: true

require 'json'
require_relative '../atomic_file'
require_relative '../generation'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Embedding
    # Collect the complete extraction input before an embedding run can mutate
    # stores. Native publications use their authoritative listings, never a glob
    # that could mistake a missing/corrupt payload for intentional deletion.
    class Corpus
      class Incomplete < Woods::Error; end

      def initialize(output_dir)
        @output_dir = output_dir.to_s
      end

      def load
        native? ? published_units : legacy_units
      rescue IOError, SystemCallError, JSON::ParserError, EncodingError, ArgumentError => e
        raise Incomplete, "Embedding input incomplete: #{e.message}. Repair or rebuild extraction before embedding."
      end

      private

      def native?
        path = File.join(@output_dir, Generation::FILENAME)
        unless File.exist?(path)
          if File.directory?(File.join(@output_dir, 'payloads'))
            raise IOError, 'missing generation marker beside payloads'
          end

          return false
        end

        marker = JSON.parse(AtomicFile.read(path))
        raise IOError, 'invalid generation marker' unless marker.is_a?(Hash)
        return false if marker['payload'].nil?

        validate_marker(marker)
        true
      end

      def validate_marker(marker)
        strings_valid = %w[payload token].all? { |key| marker[key].is_a?(String) && !marker[key].empty? }
        return if strings_valid && marker['number'].is_a?(Integer) && marker['number'].positive?

        raise IOError, 'invalid published generation marker'
      end

      def published_units
        require_relative '../mcp/index_reader'

        reader = MCP::IndexReader.new(@output_dir)
        reader.with_pinned_generation do
          # Generation's compatibility fallback to the root is useful for
          # readers, but cannot prove completeness for destructive reconciliation.
          if reader.payload_dir.expand_path == Pathname.new(@output_dir).expand_path
            raise IOError,
                  'published payload missing or invalid'
          end

          validate_counts(reader.manifest)
          reader.each_unit.to_a
        end
      end

      def validate_counts(manifest)
        counts = manifest.is_a?(Hash) && manifest['counts']
        valid = counts.is_a?(Hash) && counts.all? do |dir, count|
          MCP::IndexReader::TYPE_DIRS.include?(dir) && count.is_a?(Integer) && count >= 0
        end
        raise IOError, 'invalid published manifest counts' unless valid
      end

      # Pre-pointer indexes may use arbitrary filenames and have no manifest
      # or authoritative listing. Keep that input contract, but never silently
      # omit unreadable JSON before reconciling persisted identities.
      def legacy_units
        Dir.glob(File.join(@output_dir, '**', '*.json')).filter_map do |path|
          relative = path.delete_prefix("#{@output_dir}/")
          next if relative.start_with?('dumps/', 'payloads/') || File.basename(path) == 'checkpoint.json'

          data = JSON.parse(AtomicFile.read(path))
          data if data.is_a?(Hash) && data.key?('type') && data.key?('identifier')
        end
      end
    end
  end
end
