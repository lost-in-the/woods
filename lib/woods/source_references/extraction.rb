# frozen_string_literal: true

require_relative 'pass'
require_relative 'cache'
require_relative 'projector'

module Woods
  module SourceReferences
    # Pipeline hooks keep candidate cache, typed forward edges and reverse graph
    # publication in one generation. A reference-only rewrite is not extraction
    # and must not refresh runtime metadata, timestamps or Git facts.
    module Extraction # rubocop:disable Metrics/ModuleLength -- shared full/incremental atomic publication hooks
      private

      def enrich_source_references_full
        units = @results.values.flatten
        records = units.map { |unit| reference_record(unit) }
        result = reference_pass(records, full: true)
        @source_reference_occurrences = result.references
        units.each do |unit|
          edges = result.dependencies[[unit.type.to_s, unit.identifier]]
          next unless edges

          # Full extraction only adds records, so retain each extractor's exact
          # in-memory representations for its existing specialized relationships.
          unit.dependencies += internal_reference_edges(edges.drop(unit.dependencies.size))
        end
        write_source_reference_cache(result)
      end

      # Full extraction builds line maps after the reference pass. Projection
      # belongs here, after normalization and before any unit is serialized.
      def project_source_references_full
        projector = source_reference_projector
        @results.values.flatten.each do |unit|
          key = [unit.type.to_s, unit.identifier]
          raw = @source_reference_occurrences&.fetch(key, []) || []
          unit.metadata[:references] = projector.call(reference_record(unit), raw)
        end
      end

      def source_reference_projector
        Projector.new(source_reader: ->(path) { @source_inputs.read_source(path).fetch('source') })
      end

      def internal_reference_edges(edges)
        edges.map do |edge|
          edge.transform_keys(&:to_sym).merge(type: edge.fetch('type').to_sym, via: edge.fetch('via').to_sym)
        end
      end

      def reference_record(unit)
        { 'type' => unit.type.to_s, 'identifier' => unit.identifier, 'file_path' => unit.file_path,
          'source_code' => unit.source_code, 'metadata' => JSON.parse(JSON.generate(unit.metadata)),
          'dependencies' => JSON.parse(JSON.generate(unit.dependencies)) }
      end

      # Called before any incremental consumer mutates the seeded generation.
      def prepare_source_reference_baseline
        discarding_seed_on_refusal do
          @source_reference_baseline = Cache.read(payload_dir.join(Cache::FILE_NAME))
          empty_source_reference_baseline! unless @source_reference_baseline
        rescue Cache::Invalid
          empty_source_reference_baseline!
        end
      end

      # A refused run is never published, so nothing references the payload
      # seeded for it. Leaving it would only wait for the next run's create
      # to empty it; the active generation's payload is never touched.
      def discarding_seed_on_refusal
        yield
      rescue RebuildRequired
        discard_unpublished_seed
        raise
      end

      # +payload_dir+ falls back to the output root when no payload was
      # opened; that root holds every published generation.
      def discard_unpublished_seed
        seed = payload_dir
        return if File.expand_path(seed) == File.expand_path(@output_dir)

        active = Generation.new(output_dir: @output_dir).current.payload
        return if active && File.expand_path(active, @output_dir) == File.expand_path(seed)

        FileUtils.rm_rf(seed.to_s)
      end

      def empty_source_reference_baseline!
        if source_reference_identities.any? { |type, identifier| source_reference_node?(type, identifier) }
          raise RebuildRequired,
                'Source-reference baseline is missing or incompatible. Run bin/rails woods:extract once for a full ' \
                'extraction; the previous published generation remains active. ' \
                'woods:validate reports incremental readiness.'
        end
        @source_reference_baseline = { 'version' => Cache::VERSION, 'callers' => source_reference_policy.to_h,
                                       'files' => {}, 'owners' => [] }
      end

      def source_reference_node?(type, identifier)
        return false unless Registry::TYPES.include?(type)
        return false unless RuntimeLookup::CONSTANT.match?(identifier)

        path = @dependency_graph.node(identifier, type: type)[:file_path]
        return false if path.nil?

        relative = File.expand_path(path, Rails.root).delete_prefix("#{File.expand_path(Rails.root)}/")
        relative.match?(%r{\A(?:app|lib)/.*\.rb\z}) &&
          relative.split('/').none? { |part| %w[vendor node_modules assets].include?(part) }
      end

      def source_reference_identities
        @dependency_graph.typed_identifiers
      end

      def enrich_source_references_incremental(affected_types)
        records = source_reference_payload_records
        result = discarding_seed_on_refusal do
          reference_pass(records.values.map { |entry| reference_pass_unit(entry.fetch(:data)) }, full: false)
        end
        touched = Set.new
        projector = source_reference_projector
        result.dependencies.each do |identity, edges|
          record = records.fetch(identity)
          next unless record[:path]

          data = record.fetch(:data)
          references = projector.call(data, result.references.fetch(identity))
          next if source_reference_unchanged?(data, edges, references)

          rewrite_source_references(record, edges, references, affected_types)
          touched.add(identity.last)
        end
        write_source_reference_cache(result)
        touched
      end

      def source_reference_unchanged?(data, edges, references)
        data.fetch('dependencies', []) == edges && data.dig('metadata', 'references') == references
      end

      # A retained unit ({Extractor#retain_unit}) is fresh to the pass, which
      # takes a fresh unit's dependencies as the extractor's own. Its published
      # JSON still carries the previous pass's additions, so they come off
      # here; left in, the next cache would record no ownership for them.
      def reference_pass_unit(data)
        key = data.values_at('type', 'identifier')
        return data unless @retained_units&.include?(key)

        own = ExtractedForm.own_dependencies(data['dependencies'], reference_additions[key])
        own ? data.merge('dependencies' => own) : data
      end

      def source_reference_payload_records
        owned = Array(@source_reference_baseline&.fetch('owners')).to_set do |owner|
          [owner['type'], owner['identifier']]
        end
        policy = source_reference_policy
        source_reference_identities.to_h do |type, identifier|
          read_caller = policy.caller?(type) &&
                        (source_reference_node?(type, identifier) || owned.include?([type.to_s, identifier]))
          record = if read_caller
                     source_reference_caller_record(type, identifier)
                   else
                     node = @dependency_graph.node(identifier, type: type)
                     { data: { 'type' => type.to_s, 'identifier' => identifier,
                               'file_path' => node[:file_path], 'dependencies' => [] } }
                   end
          [[type.to_s, identifier], record]
        end
      end

      def source_reference_caller_record(type, identifier)
        key = self.class::TYPE_TO_EXTRACTOR_KEY.fetch(type)
        path = payload_dir.join(key.to_s, collision_safe_filename(identifier))
        data = JSON.parse(AtomicFile.read(path))
        unless data.is_a?(Hash) && data['type'] == type.to_s && data['identifier'] == identifier
          raise Woods::ExtractionError, "Source-reference unit identity mismatch for #{type}:#{identifier}"
        end

        { data: data, path: path, extractor_key: key }
      end

      def reference_pass(units, full:)
        Pass.new(root: Rails.root, session: @source_inputs, units: units,
                 extractor_keys: self.class::TYPE_TO_EXTRACTOR_KEY, baseline: @source_reference_baseline,
                 refreshed: @source_reference_refreshed || [], full: full, collector: source_collector,
                 policy: source_reference_policy).call
      end

      def source_reference_policy
        CallerPolicy.new(Woods.configuration.source_reference_callers)
      end

      def rewrite_source_references(record, edges, references, affected_types)
        data = record.fetch(:data)
        (data['metadata'] ||= {})['references'] = references
        rewrite_source_reference_edges(record, edges, affected_types)
      end

      # Shared with documentation: preserve metadata unless the owning pass changed it.
      def rewrite_source_reference_edges(record, edges, affected_types)
        data = record.fetch(:data)
        type = data.fetch('type').to_sym
        identifier = data.fetch('identifier')
        node = @dependency_graph.node(identifier, type: type)
        unit = reference_unit(data, node, edges)
        mark_dependents_dirty(identifier)
        @dependency_graph.register(unit)
        @dependency_graph.annotate(identifier, type: type, **DependencyGraph.persisted_node_attributes(node))
        mark_dependents_dirty(identifier)
        data['dependencies'] = edges
        AtomicFile.write(record.fetch(:path), json_serialize(data), durable: payload_writes_durable?)
        affected_types.add(record.fetch(:extractor_key))
      end

      def reference_unit(data, node, edges)
        unit = ExtractedUnit.new(type: data.fetch('type').to_sym, identifier: data.fetch('identifier'),
                                 file_path: node[:file_path])
        unit.namespace = node[:namespace]
        unit.metadata = data.fetch('metadata', {})
        unit.dependencies = edges
        unit
      end

      def write_source_reference_cache(result)
        Cache.write(payload_dir.join(Cache::FILE_NAME), result.cache)
        @source_reference_paths = result.paths.to_set
      end

      # The final source scan is already required by provenance publication.
      # Reuse it to reject graph evidence whose captured inputs became unstable.
      def verify_source_reference_publication!(manifest)
        return if @source_reference_paths.nil? || @source_reference_paths.empty?

        errors = manifest.data.fetch('errors')
        unstable = errors.select do |error|
          %w[source_changed_during_extraction source_changed_during_read source_file_unreadable
             source_tree_unavailable external_source_path nonregular_source unverified_symlink_directory
             undecodable_source_path
             scan_time_budget scan_file_budget scan_byte_budget].include?(error['reason'])
        end
        return if unstable.empty?

        raise Woods::ExtractionError,
              'Source-reference source changed or could not be verified before publication ' \
              "(#{source_verification_details(unstable)})"
      end

      def source_verification_details(errors)
        details = errors.first(3).map do |error|
          path = error['path']
          path ? "#{error['reason']}: #{SourcePathEncoding.diagnostic(path)}" : error['reason']
        end
        details << "#{errors.size - 3} more source verification errors" if errors.size > 3
        details.join('; ')
      end
    end
  end
end
