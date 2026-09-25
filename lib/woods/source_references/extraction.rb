# frozen_string_literal: true

require_relative 'pass'
require_relative 'cache'

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
        units.each do |unit|
          edges = result.dependencies[[unit.type.to_s, unit.identifier]]
          next unless edges

          # Full extraction only adds records, so retain each extractor's exact
          # in-memory representations for its existing specialized relationships.
          unit.dependencies += internal_reference_edges(edges.drop(unit.dependencies.size))
        end
        write_source_reference_cache(result)
      end

      def internal_reference_edges(edges)
        edges.map do |edge|
          edge.transform_keys(&:to_sym).merge(type: edge.fetch('type').to_sym, via: edge.fetch('via').to_sym)
        end
      end

      def reference_record(unit)
        { 'type' => unit.type.to_s, 'identifier' => unit.identifier, 'file_path' => unit.file_path,
          'metadata' => unit.metadata, 'dependencies' => JSON.parse(JSON.generate(unit.dependencies)) }
      end

      # Called before any incremental consumer mutates the seeded generation.
      def prepare_source_reference_baseline
        @source_reference_baseline = Cache.read(payload_dir.join(Cache::FILE_NAME))
        return if @source_reference_baseline

        empty_source_reference_baseline!
      rescue Cache::Invalid
        empty_source_reference_baseline!
      end

      def empty_source_reference_baseline!
        if source_reference_identities.any? { |type, identifier| source_reference_node?(type, identifier) }
          raise RebuildRequired,
                'Source-reference baseline is missing or incompatible. Run bin/rails woods:extract once for a full ' \
                'extraction; the previous published generation remains active.'
        end
        @source_reference_baseline = { 'version' => Cache::VERSION, 'files' => {}, 'owners' => [] }
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
        @dependency_graph.to_h.fetch(:type_index).flat_map do |type, identifiers|
          identifiers.map { |identifier| [type.to_sym, identifier] }
        end
      end

      def enrich_source_references_incremental(affected_types)
        records = source_reference_payload_records
        result = reference_pass(records.values.map { |entry| entry.fetch(:data) }, full: false)
        touched = Set.new
        result.dependencies.each do |identity, edges|
          record = records.fetch(identity)
          next if record.fetch(:data).fetch('dependencies', []) == edges

          rewrite_source_reference_edges(record, edges, affected_types)
          touched.add(identity.last)
        end
        write_source_reference_cache(result)
        touched
      end

      def source_reference_payload_records
        owned = Array(@source_reference_baseline&.fetch('owners')).to_set do |owner|
          [owner['type'], owner['identifier']]
        end
        source_reference_identities.to_h do |type, identifier|
          read_caller = Pass::CALLER_TYPES.include?(type.to_s) &&
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
                 refreshed: @source_reference_refreshed || [], full: full).call
      end

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
