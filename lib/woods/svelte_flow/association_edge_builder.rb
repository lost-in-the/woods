# frozen_string_literal: true

require 'set'

module Woods
  module SvelteFlow
    # Builds ERD-style edges from association metadata.
    #
    # Unlike EdgeBuilder (which reads flat dependency edges from DependencyGraph),
    # this class reads rich association metadata from unit_metadata to produce
    # edges with FK→PK handle routing, relationship type, and cardinality info.
    #
    # Edge direction convention: source always holds the FK column, target holds the PK.
    # belongs_to edges keep natural direction. has_many/has_one edges are flipped so
    # the FK-holding model is always the source.
    #
    # Deduplication: Rails associations are bidirectional (Account has_many :orders,
    # Order belongs_to :account). We deduplicate by canonical key:
    # "{fk_table}-{fk_column}-{pk_table}". First occurrence wins.
    #
    # @example
    #   builder = AssociationEdgeBuilder.new(
    #     unit_metadata: metadata_hash,
    #     cycle_edges: Set.new([["Order", "Account"]])
    #   )
    #   builder.build  # => [{ "id" => "assoc-...", "source" => "Order", ... }]
    #
    class AssociationEdgeBuilder
      # @param unit_metadata [Hash<String, Hash>] Raw unit metadata keyed by identifier
      # @param cycle_edges [Set<Array<String>>] Set of [source, target] pairs forming cycles
      def initialize(unit_metadata:, cycle_edges: Set.new)
        @unit_metadata = unit_metadata
        @cycle_edges = cycle_edges
      end

      # Build Svelte Flow edge objects for all model associations.
      #
      # @return [Array<Hash>] Svelte Flow edge objects with ERD semantics
      def build
        seen = Set.new
        edges = []

        @unit_metadata.each do |identifier, unit|
          unit_type = (unit['type'] || unit[:type])&.to_s
          next unless unit_type == 'model'

          metadata = unit['metadata'] || unit[:metadata] || {}
          associations = metadata['associations'] || metadata[:associations] || []
          primary_key = metadata['primary_key'] || metadata[:primary_key] || 'id'

          associations.each do |assoc|
            edge = build_association_edge(identifier, primary_key, assoc)
            next unless edge

            canonical = edge[:canonical_key]
            next if seen.include?(canonical)

            seen.add(canonical)
            edges << edge[:edge]
          end
        end

        edges
      end

      private

      # Build a single association edge with FK→PK direction.
      #
      # @param identifier [String] Source model identifier
      # @param primary_key [String] Source model's primary key column
      # @param assoc [Hash] Association metadata
      # @return [Hash, nil] { canonical_key:, edge: } or nil if target not in metadata
      def build_association_edge(identifier, primary_key, assoc) # rubocop:disable Metrics/MethodLength
        macro = (assoc['type'] || assoc[:type])&.to_s
        target = assoc['target'] || assoc[:target]
        foreign_key = (assoc['foreign_key'] || assoc[:foreign_key])&.to_s
        through = assoc['through'] || assoc[:through]
        polymorphic = assoc['polymorphic'] || assoc[:polymorphic] || false

        return nil unless target && @unit_metadata.key?(target)
        return nil unless foreign_key

        target_meta = @unit_metadata[target]
        target_pk = resolve_primary_key(target_meta)

        source_model, target_model, source_handle, target_handle =
          resolve_direction(identifier, target, foreign_key, primary_key, target_pk, macro)

        canonical_key = "#{source_model}-#{foreign_key}-#{target_model}"
        is_cycle = @cycle_edges.include?([identifier, target]) ||
                   @cycle_edges.include?([target, identifier])

        edge_id = "assoc-#{identifier}-#{macro}-#{target}-#{foreign_key}"

        {
          canonical_key: canonical_key,
          edge: {
            'id' => edge_id,
            'source' => source_model,
            'target' => target_model,
            'type' => 'association',
            'data' => {
              'via' => macro,
              'foreignKey' => foreign_key,
              'sourceHandle' => source_handle,
              'targetHandle' => target_handle,
              'through' => through&.to_s,
              'polymorphic' => polymorphic,
              'isCycle' => is_cycle
            }
          }
        }
      end

      # Resolve edge direction so source always holds the FK.
      #
      # @param identifier [String] The model declaring the association
      # @param target [String] The associated model
      # @param foreign_key [String] The FK column name
      # @param my_pk [String] The declaring model's primary key
      # @param target_pk [String] The target model's primary key
      # @param macro [String] Association type (belongs_to, has_many, has_one, etc.)
      # @return [Array<String>] [source_model, target_model, source_handle, target_handle]
      def resolve_direction(identifier, target, foreign_key, my_pk, target_pk, macro)
        case macro
        when 'belongs_to'
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        when 'has_many', 'has_one'
          [target, identifier, "#{target}-#{foreign_key}", "#{identifier}-#{my_pk}"]
        when 'has_and_belongs_to_many'
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        else
          [identifier, target, "#{identifier}-#{foreign_key}", "#{target}-#{target_pk}"]
        end
      end

      # Resolve the primary key for a target model from its metadata.
      #
      # @param target_meta [Hash] Unit metadata for the target model
      # @return [String]
      def resolve_primary_key(target_meta)
        meta = target_meta['metadata'] || target_meta[:metadata] || {}
        meta['primary_key'] || meta[:primary_key] || 'id'
      end
    end
  end
end
