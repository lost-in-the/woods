# frozen_string_literal: true

require 'set'
require 'woods'
require_relative 'collector'
require_relative 'registry'
require_relative 'inputs'
require_relative 'cache'
require_relative 'caller_policy'
require_relative 'declarations'

module Woods
  module SourceReferences
    # Retained references cannot be reconstructed safely from current bytes when
    # their extraction provenance or edge ownership is unavailable.
    class RebuildRequired < Woods::ExtractionError; end

    # Resolves candidates against the complete current typed registry. Parsing is
    # cached by captured HMAC, including candidates whose targets do not yet exist.
    # Runtime lookup is repeated every run: source text alone cannot fingerprint
    # changed ancestors, aliases or lexical shadows in a reloaded application.
    class Pass # rubocop:disable Metrics/ClassLength -- keep ownership, policy and edge merging together
      Result = Struct.new(:dependencies, :references, :cache, :paths, keyword_init: true)

      # @param root [String, Pathname] application root
      # @param session [SourceInputs::Session] original source capture
      # @param units [Array<Hash>] complete string-keyed typed unit set
      # @param extractor_keys [Hash{Symbol => Symbol}] unit type to consumer key
      # @param baseline [Hash, nil] validated preceding generation cache
      # @param refreshed [Array<Array<String>>] units genuinely re-extracted
      # @param full [Boolean] all runtime units were re-extracted
      # @param collector [Collector] source-only parser
      # @param policy [CallerPolicy] caller types and the targets each may reference
      # rubocop:disable Metrics/ParameterLists -- explicit per-run collaborators and provenance state
      def initialize(root:, session:, units:, extractor_keys:, baseline: nil, refreshed: [], full: false,
                     collector: Collector.new, policy: CallerPolicy.new)
        @root = File.expand_path(root.to_s)
        @session = session
        @units = units
        @keys = extractor_keys
        @baseline = baseline
        @refreshed = refreshed.to_set
        @full = full
        @collector = collector
        @policy = policy
      end

      # rubocop:enable Metrics/ParameterLists

      # @return [Result] dependency replacements, admitted raw occurrences and next cache
      def call
        verify_baseline! unless @full

        @inputs = Inputs.new(root: @root, session: @session, collector: @collector)
        @files = @inputs.call(units: @units, baseline: @baseline, fresh: method(:fresh?), extractor_keys: @keys)
        sources = @files.transform_values { |entry| entry['analysis'] }
        @registry = Registry.new(units: @units, sources: sources, root: @root)
        @previous = Array(@baseline&.fetch('owners')).to_h { |owner| [[owner['type'], owner['identifier']], owner] }
        build_result
      end

      private

      # Edges the previous policy added stay in retained units, so a changed
      # policy cannot be applied to them piecemeal.
      def verify_baseline!
        raise_rebuild('reference cache is missing') unless @baseline
        raise_rebuild('source_reference_callers changed') unless @baseline['callers'] == @policy.to_h
      end

      def build_result
        dependencies = {}
        references = {}
        owners = @units.filter_map do |unit|
          key = [unit['type'], unit['identifier']]
          path = @inputs.relative(unit['file_path'])
          additions = []
          dependencies[key], additions, references[key] = resolved_caller(unit, key) if @policy.caller?(unit['type'])
          # Target-only units also crossed Inputs' consumption gate. Retain
          # their exact ownership so bounded freshness can reuse that proof.
          owner_record(unit, path, additions)
        end
        owners.sort_by! { |owner| [owner['type'], owner['identifier']] }
        cache = { 'version' => Cache::VERSION, 'callers' => @policy.to_h, 'files' => @files, 'owners' => owners }
        Result.new(dependencies: dependencies, references: references, cache: cache, paths: @files.keys)
      end

      def resolved_caller(unit, key)
        base = original_dependencies(unit, key)
        occurrences = resolved_occurrences(unit)
        edges = occurrences.filter_map(&:first).uniq.sort_by { |edge| edge.values_at('type', 'target', 'via') }
        additions = edges.reject { |edge| pair_present?(base, edge) }
        [base + additions, additions, occurrences.map(&:last)]
      end

      def owner_record(unit, path, additions)
        return unless Registry::TYPES.include?(unit['type']&.to_sym)
        return unless @files.key?(path) && RuntimeLookup::CONSTANT.match?(unit['identifier'].to_s)

        record = { 'type' => unit['type'], 'identifier' => unit['identifier'], 'file_path' => path,
                   'added' => additions }
        record['file_paths'] = reference_paths(unit) if SourceContributors.multiple?(unit)
        record
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
           !same_owner_paths?(prior, unit, path)
          raise_rebuild("reference ownership is missing or incompatible for #{key.join(':')}")
        end
        prior
      end

      def resolved_occurrences(unit)
        reference_paths(unit).flat_map do |source|
          occurrences_in(unit,
                         source) + Declarations.new(unit, @registry, @policy).call(macros_in(unit, source), source)
        end
      end

      def macros_in(unit, path)
        Array(@files.dig(path, 'analysis', 'macros')).select { |record| record['owner'] == unit['identifier'] }
      end

      def same_owner_paths?(prior, unit, path)
        prior && prior['file_path'] == path && (prior['file_paths'] || [path]) == reference_paths(unit)
      end

      def reference_paths(unit)
        SourceContributors.paths(unit).map { |path| @inputs.relative(path) }
      end

      # Edge labels an extractor gives a component it renders or declares as
      # a slot. The constant read behind them is the same relationship.
      STATED_BY_RENDER = %w[render slot].freeze
      private_constant :STATED_BY_RENDER

      # An extractor may already carry the pair with a guessed type; a second
      # entry for the same relationship would double count in the graph. A
      # `render` or `slot` edge states the reference its constant read would
      # add, so only a component mentioned outside a render (constructed and
      # passed on, compared with `is_a?`, handed over as a constant) gains a
      # `code_reference` edge (LOS-123). Its occurrence is still a span.
      def pair_present?(edges, edge)
        target, via = edge.values_at('target', 'via')
        edges.any? do |existing|
          next false unless existing['target'] == target

          existing['via'] == via || (via == 'code_reference' && STATED_BY_RENDER.include?(existing['via']))
        end
      end

      def normalize_edge(edge)
        edge.transform_keys(&:to_s).transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
      end

      # Verified occurrences carry their edge; static and ambiguous ones are
      # published spans only and never add a dependency.
      def occurrences_in(unit, path)
        records = @files.dig(path, 'analysis', 'references') || []
        records.filter_map do |reference|
          next unless reference['owner'] == unit['identifier']

          result = @registry.explain(reference, file_path: path)
          next candidate_occurrence(unit, reference, result, path) unless result['status'] == 'resolved'

          edge = { 'type' => result.fetch('type'), 'target' => result.fetch('target'), 'via' => 'code_reference' }
          next unless @policy.permits?(unit['type'], edge['type'].to_sym)

          span = reference.slice('line', 'column', 'length', 'method', 'mixin').merge(
            'file_path' => path, 'target' => edge['target'], 'target_type' => edge['type'],
            'kind' => 'constant', 'confidence' => 'verified'
          )
          [edge, span]
        end
      end

      # One typed candidate is `static`; several are `ambiguous`, each listed.
      def candidate_occurrence(unit, reference, result, path)
        candidates = @registry.candidates(reference, result).select do |_, type|
          @policy.permits?(unit['type'], type.to_sym)
        end
        return if candidates.empty?

        span = reference.slice('line', 'column', 'length', 'method').merge('file_path' => path, 'kind' => 'constant')
        if candidates.one?
          target, type = candidates.first
          return [nil, span.merge('target' => target, 'target_type' => type, 'confidence' => 'static')]
        end

        [nil, span.merge('confidence' => 'ambiguous',
                         'candidates' => candidates.map do |target, type|
                           { 'target' => target, 'target_type' => type }
                         end)]
      end

      def raise_rebuild(reason)
        raise RebuildRequired, "Source-reference baseline needs a full extraction (#{reason}). " \
                               'Run bin/rails woods:extract; the previous published generation remains active.'
      end
    end
  end
end
