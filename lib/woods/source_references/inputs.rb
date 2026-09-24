# frozen_string_literal: true

require_relative 'registry'
require_relative '../source_inputs/stable_reader'

module Woods
  module SourceReferences
    # Collects original, captured sources once per path and reuses only candidates
    # whose keyed identity still matches. Reads never advance runtime provenance.
    class Inputs
      MAX_SOURCE_BYTES = 256 * 1024 * 1024

      # @param root [String] application root
      # @param session [SourceInputs::Session] per-run capture and consumer ledger
      # @param collector [Collector] source-only parser
      def initialize(root:, session:, collector:)
        @root = File.expand_path(root.to_s)
        @session = session
        @collector = collector
      end

      # @param units [Array<Hash>] complete typed unit set
      # @param baseline [Hash, nil] validated prior cache
      # @param fresh [Proc] true only for genuinely re-extracted units
      # @param extractor_keys [Hash{Symbol => Symbol}] consumer mapping
      # @return [Hash] relative paths to identity and candidate evidence
      def call(units:, baseline:, fresh:, extractor_keys:)
        @bytes = 0
        @baseline = baseline
        grouped = units.select { |unit| eligible?(unit) }.group_by { |unit| relative(unit['file_path']) }
        grouped.keys.sort.each_with_object({}) do |path, files|
          identity = captured_identity(path)
          next unless identity

          grouped.fetch(path).each { |unit| verify_consumption(unit, path, fresh, extractor_keys) }
          files[path] = analysis(path, identity)
        end
      end

      # @param path [String, nil] unit source path
      # @return [String, nil] application-relative path, or nil outside the root
      def relative(path)
        return if path.nil? || path.to_s.empty?

        absolute = File.expand_path(path.to_s, @root)
        absolute.delete_prefix("#{@root}/") if absolute.start_with?("#{@root}/")
      end

      private

      def eligible?(unit)
        path = relative(unit['file_path'])
        Registry::TYPES.include?(unit['type']&.to_sym) && eligible_path?(path) &&
          RuntimeLookup::CONSTANT.match?(unit['identifier'].to_s)
      end

      def eligible_path?(path)
        path&.end_with?('.rb') && path.match?(%r{\A(?:app|lib)/}) &&
          path.split('/').none? { |part| %w[vendor node_modules assets].include?(part) }
      end

      def captured_identity(path)
        identity = @session.source_identity(path)
        absolute = File.join(@root, path)
        if identity.nil? && (File.exist?(absolute) || File.symlink?(absolute))
          raise Woods::ExtractionError, "Source-reference input was not captured: #{path}"
        end

        identity
      end

      def analysis(path, identity)
        prior = @baseline&.fetch('files')&.[](path)
        return prior if prior && prior['identity'] == identity

        source = stable_source(path)
        @bytes += source.fetch('source').bytesize
        raise Woods::ExtractionError, 'Source-reference parse byte budget exceeded' if @bytes > MAX_SOURCE_BYTES

        result = @collector.call(source.fetch('source'))
        raise Woods::ExtractionError, "Could not parse source references in #{path}" if result['parse_error']

        { 'identity' => source.fetch('identity'), 'analysis' => result }
      end

      def stable_source(path)
        @session.read_source(path)
      rescue SourceInputs::StableReader::Error => e
        raise Woods::ExtractionError, "Could not verify source references in #{path}: #{e.reason}. " \
                                      'Retry the complete extraction batch in a fresh process against stable source; ' \
                                      'the previous published generation remains active.'
      end

      def verify_consumption(unit, path, fresh, extractor_keys)
        return if fresh.call(unit)

        consumer = extractor_keys[unit['type'].to_sym]
        unchanged = @baseline&.dig('files', path, 'identity') == @session.source_identity(path)
        return if unchanged && consumer && @session.consumed_source?(consumer, path)

        raise RebuildRequired, "Source-reference baseline needs a full extraction: unverified source #{path}. " \
                               'Run bin/rails woods:extract; the previous published generation remains active.'
      end
    end
  end
end
