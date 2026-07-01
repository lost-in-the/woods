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

        each_model_association do |identifier, primary_key, assoc|
          edge = build_association_edge(identifier, primary_key, assoc)
          next unless edge

          canonical = edge[:canonical_key]
          next if seen.include?(canonical)

          seen.add(canonical)
          edges << edge[:edge]
        end

        edges
      end

      private

      # Yield [identifier, primary_key, association] for every association on
      # every model unit in the metadata.
      #
      # @yieldparam identifier [String] Model identifier
      # @yieldparam primary_key [String] Model's primary key column
      # @yieldparam assoc [Hash] A single association metadata hash
      # @return [void]
      def each_model_association
        @unit_metadata.each do |identifier, unit|
          next unless model?(unit)

          metadata = fetch_either(unit, :metadata) || {}
          primary_key = fetch_either(metadata, :primary_key) || 'id'
          associations = fetch_either(metadata, :associations) || []

          associations.each { |assoc| yield identifier, primary_key, assoc }
        end
      end

      # Whether a unit metadata entry describes a model.
      #
      # @param unit [Hash] Unit metadata
      # @return [Boolean]
      def model?(unit)
        fetch_either(unit, :type)&.to_s == 'model'
      end

      # Fetch a key from a hash tolerating either string or symbol keys.
      #
      # @param hash [Hash, nil]
      # @param key [Symbol]
      # @return [Object, nil]
      def fetch_either(hash, key)
        return if hash.nil?

        hash[key.to_s] || hash[key]
      end

      # Build a single association edge with FK→PK direction.
      #
      # @param identifier [String] Source model identifier
      # @param primary_key [String] Source model's primary key column
      # @param assoc [Hash] Association metadata
      # @return [Hash, nil] { canonical_key:, edge: } or nil if target not in metadata
      def build_association_edge(identifier, primary_key, assoc) # rubocop:disable Metrics/MethodLength
        f = association_fields(assoc)
        return nil unless f[:target] && @unit_metadata.key?(f[:target])
        return nil unless f[:foreign_key]

        target = f[:target]
        foreign_key = f[:foreign_key]
        macro = f[:macro]
        target_pk = resolve_primary_key(@unit_metadata[target])

        source_model, target_model, source_handle, target_handle =
          resolve_direction([identifier, primary_key], [target, target_pk], foreign_key, macro)

        {
          canonical_key: "#{source_model}-#{foreign_key}-#{target_model}",
          edge: {
            'id' => "assoc-#{identifier}-#{macro}-#{target}-#{foreign_key}",
            'source' => source_model,
            'target' => target_model,
            'type' => 'association',
            'data' => {
              'via' => macro,
              'foreignKey' => foreign_key,
              'sourceHandle' => source_handle,
              'targetHandle' => target_handle,
              'through' => f[:through]&.to_s,
              'polymorphic' => f[:polymorphic],
              'isCycle' => cycle?(identifier, target)
            }
          }
        }
      end

      # Extract association fields, tolerating both symbol- and string-keyed metadata.
      #
      # @param assoc [Hash] Association metadata
      # @return [Hash] { macro:, target:, foreign_key:, through:, polymorphic: }
      def association_fields(assoc)
        {
          macro: fetch_either(assoc, :type)&.to_s,
          target: fetch_either(assoc, :target),
          foreign_key: fetch_either(assoc, :foreign_key)&.to_s,
          through: fetch_either(assoc, :through),
          polymorphic: fetch_either(assoc, :polymorphic) || false
        }
      end

      # Whether an edge between two models participates in a dependency cycle
      # (in either direction).
      #
      # @return [Boolean]
      def cycle?(identifier, target)
        @cycle_edges.include?([identifier, target]) || @cycle_edges.include?([target, identifier])
      end

      # Resolve edge direction so the source model always holds the FK.
      #
      # belongs_to (and habtm / anything else) keeps natural direction: the
      # declaring model is the source. has_many / has_one are flipped so the
      # FK-holding associate becomes the source.
      #
      # @param declarer [Array(String, String)] [declaring model, its primary key]
      # @param associate [Array(String, String)] [associated model, its primary key]
      # @param foreign_key [String] The FK column name
      # @param macro [String] Association type (belongs_to, has_many, has_one, etc.)
      # @return [Array<String>] [source_model, target_model, source_handle, target_handle]
      def resolve_direction(declarer, associate, foreign_key, macro)
        d_model, d_pk = declarer
        a_model, a_pk = associate

        if %w[has_many has_one].include?(macro)
          [a_model, d_model, "#{a_model}-#{foreign_key}", "#{d_model}-#{d_pk}"]
        else
          [d_model, a_model, "#{d_model}-#{foreign_key}", "#{a_model}-#{a_pk}"]
        end
      end

      # Resolve the primary key for a target model from its metadata.
      #
      # @param target_meta [Hash] Unit metadata for the target model
      # @return [String]
      def resolve_primary_key(target_meta)
        meta = fetch_either(target_meta, :metadata) || {}
        fetch_either(meta, :primary_key) || 'id'
      end
    end
  end
end
