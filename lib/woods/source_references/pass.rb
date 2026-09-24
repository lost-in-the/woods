# frozen_string_literal: true

require 'set'
require 'woods'
require_relative 'collector'
require_relative 'registry'
require_relative 'inputs'
require_relative 'cache'

module Woods
  module SourceReferences
    # Retained references cannot be reconstructed safely from current bytes when
    # their extraction provenance or edge ownership is unavailable.
    class RebuildRequired < Woods::ExtractionError; end

    # Resolves candidates against the complete current typed registry. Parsing is
    # cached by captured HMAC, including candidates whose targets do not yet exist.
    # Runtime lookup is repeated every run: source text alone cannot fingerprint
    # changed ancestors, aliases or lexical shadows in a reloaded application.
    class Pass
      CALLER_TYPES = %w[model controller service poro lib concern].freeze
      Result = Struct.new(:dependencies, :cache, :paths, keyword_init: true)

      # @param root [String, Pathname] application root
      # @param session [SourceInputs::Session] original source capture
      # @param units [Array<Hash>] complete string-keyed typed unit set
      # @param extractor_keys [Hash{Symbol => Symbol}] unit type to consumer key
      # @param baseline [Hash, nil] validated preceding generation cache
      # @param refreshed [Array<Array<String>>] units genuinely re-extracted
      # @param full [Boolean] all runtime units were re-extracted
      # @param collector [Collector] source-only parser
      # rubocop:disable Metrics/ParameterLists -- explicit per-run collaborators and provenance state
      def initialize(root:, session:, units:, extractor_keys:, baseline: nil, refreshed: [], full: false,
                     collector: Collector.new)
        @root = File.expand_path(root.to_s)
        @session = session
        @units = units
        @keys = extractor_keys
        @baseline = baseline
        @refreshed = refreshed.to_set
        @full = full
        @collector = collector
      end

      # rubocop:enable Metrics/ParameterLists

      # @return [Result] complete dependency replacements and next cache
      def call
        raise_rebuild('reference cache is missing') if !@full && !@baseline

        @inputs = Inputs.new(root: @root, session: @session, collector: @collector)
        @files = @inputs.call(units: @units, baseline: @baseline, fresh: method(:fresh?), extractor_keys: @keys)
        sources = @files.transform_values { |entry| entry['analysis'] }
        @registry = Registry.new(units: @units, sources: sources, root: @root)
        @previous = Array(@baseline&.fetch('owners')).to_h { |owner| [[owner['type'], owner['identifier']], owner] }
        build_result
      end

      private

      def build_result
        dependencies = {}
        owners = @units.filter_map do |unit|
          next unless CALLER_TYPES.include?(unit['type'])

          key = [unit['type'], unit['identifier']]
          path = @inputs.relative(unit['file_path'])
          base = original_dependencies(unit, key)
          additions = resolved_dependencies(unit, path).reject { |edge| base.include?(edge) }
          dependencies[key] = base + additions
          owner_record(unit, path, additions)
        end
        owners.sort_by! { |owner| [owner['type'], owner['identifier']] }
        cache = { 'version' => Cache::VERSION, 'files' => @files, 'owners' => owners }
        Result.new(dependencies: dependencies, cache: cache, paths: @files.keys)
      end

      def owner_record(unit, path, additions)
        return unless @files.key?(path) && RuntimeLookup::CONSTANT.match?(unit['identifier'].to_s)

        { 'type' => unit['type'], 'identifier' => unit['identifier'], 'file_path' => path, 'added' => additions }
      end

      def fresh?(unit)
        @full || @refreshed.include?([unit['type'], unit['identifier']])
      end

      def original_dependencies(unit, key)
        dependencies = unit.fetch('dependencies', []).map { |edge| normalize_edge(edge) }
        return dependencies if @full || @refreshed.include?(key)

        prior = ownership_record(unit, key)
        return dependencies unless prior

        prior.fetch('added').each do |edge|
          position = dependencies.index(edge)
          raise_rebuild("reference ownership differs for #{key.join(':')}") unless position

          dependencies.delete_at(position)
        end
        dependencies
      end

      def ownership_record(unit, key)
        path = @inputs.relative(unit['file_path'])
        prior = @previous[key]
        expected = @files.key?(path) || @baseline.fetch('files').key?(path)
        if expected && RuntimeLookup::CONSTANT.match?(unit['identifier'].to_s) &&
           (!prior || prior['file_path'] != path)
          raise_rebuild("reference ownership is missing or incompatible for #{key.join(':')}")
        end
        prior
      end

      def normalize_edge(edge)
        edge.transform_keys(&:to_s).transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
      end

      def resolved_dependencies(unit, path)
        records = @files.dig(path, 'analysis', 'references') || []
        owned = records.select { |reference| reference['owner'] == unit['identifier'] }
        edges = owned.filter_map { |reference| @registry.resolve(reference, file_path: path) }
        edges.map! { |edge| normalize_edge(edge) }
        edges.uniq.sort_by { |edge| [edge['type'], edge['target'], edge['via']] }
      end

      def raise_rebuild(reason)
        raise RebuildRequired, "Source-reference baseline needs a full extraction (#{reason}). " \
                               'Run bin/rails woods:extract; the previous published generation remains active.'
      end
    end
  end
end
