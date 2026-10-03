# frozen_string_literal: true

require 'json'
require 'set'

module Woods
  # Links documentation units to the code they name.
  #
  # {Extractors::DocExtractor} records candidates: code mentions and relative
  # links. Whether a candidate names a unit depends on the whole index, so the
  # answer is computed here, after every extractor has run, by one resolver the
  # full and the incremental path share. A candidate that names a unit becomes
  # a `documents` edge (`doc_link` for a link to another document) and is
  # flagged `resolved`; one that names nothing stays in the unit's metadata,
  # unresolved, and produces no edge.
  #
  # Every `doc` unit is re-resolved on every run. That is what lets an
  # unchanged document gain an edge when its target is first indexed and lose
  # it when the target is deleted, without tracking which documents a change
  # could reach.
  module DocReferences
    TYPE = :doc
    MENTION_VIA = 'documents'
    LINK_VIA = 'doc_link'

    # What the index holds, keyed the ways a document can name it.
    class Registry
      # @param records [Enumerable<Hash>] `{ type:, identifier:, paths: }` per
      #   unit, with string types and root-relative paths
      def initialize(records)
        @by_identifier = {}
        @by_path = {}
        records.each do |record|
          entry = [record.fetch(:identifier), record.fetch(:type).to_s]
          (@by_identifier[entry.first] ||= []) << entry
          record.fetch(:paths).each { |path| (@by_path[path] ||= []) << entry }
        end
        @routes = @by_identifier.values.flatten(1).filter_map { |identifier, type| identifier if type == 'route' }.sort
      end

      # @param identifier [String]
      # @return [Array<Array(String, String)>] `[identifier, type]` per unit
      def units_named(identifier)
        @by_identifier.fetch(identifier, [])
      end

      # @param path [String] root-relative path
      # @return [Array<Array(String, String)>] `[identifier, type]` per unit defined there
      def units_at(path)
        @by_path.fetch(path, [])
      end

      # @param route [String] `VERB /path`
      # @return [Array<String>] identifiers of the route's constrained and numbered variants
      def route_variants(route)
        # Constrained (`GET /a [format=json]`) and numbered (`GET /a #2`) forms
        # sort directly after the bare identifier plus a space.
        prefix = "#{route} "
        first = @routes.bsearch_index { |identifier| identifier >= prefix } || @routes.size
        @routes[first..].take_while { |identifier| identifier.start_with?(prefix) }
                        .select { |identifier| identifier.start_with?("#{prefix}[", "#{prefix}#") }
      end
    end

    # Resolves one document's candidates against a {Registry}.
    class Resolver
      # @!attribute edges
      #   @return [Array<Array(String, String, String)>] sorted unique `[target, type, via]`
      # @!attribute mentions
      #   @return [Array<Boolean>] whether each mention resolved, in input order
      # @!attribute links
      #   @return [Array<Boolean>] whether each link resolved, in input order
      Result = Struct.new(:edges, :mentions, :links, keyword_init: true)

      # @param registry [Registry]
      def initialize(registry)
        @registry = registry
      end

      # @param identifier [String] the document's own identifier, never a target
      # @param mentions [Array<Array(String, String)>] `[kind, text]` candidates
      # @param links [Array<String, nil>] root-relative link paths (nil for a link with none)
      # @return [Result]
      def call(identifier:, mentions:, links:)
        @self = identifier
        edges = Set.new
        mention_flags = mentions.map { |kind, text| collect(edges, mention_targets(kind, text), MENTION_VIA).any? }
        link_flags = links.map { |path| !path.nil? && collect(edges, *link_targets(path)).any? }
        Result.new(edges: edges.to_a.sort, mentions: mention_flags, links: link_flags)
      end

      private

      def mention_targets(kind, text)
        case kind
        when 'constant' then constant_targets(text)
        when 'path' then @registry.units_at(text)
        when 'rake_task' then typed(text, 'rake_task')
        when 'route' then route_targets(text)
        else []
        end
      end

      def constant_targets(text)
        segments = text.split('::')
        segments.size.downto(1) do |count|
          found = @registry.units_named(segments.first(count).join('::'))
          return found unless found.empty?
        end
        []
      end

      def route_targets(text)
        exact = typed(text, 'route')
        exact.empty? ? @registry.route_variants(text).map { |identifier| [identifier, 'route'] } : exact
      end

      def typed(identifier, type)
        @registry.units_named(identifier).select { |entry| entry.last == type }
      end

      # @return [Array(Array, String)] the link's targets and the edge label they take
      def link_targets(path)
        documents = typed(path, TYPE.to_s)
        documents.empty? ? [@registry.units_at(path), MENTION_VIA] : [documents, LINK_VIA]
      end

      # @return [Array] the targets added: every one but the document itself
      def collect(edges, targets, via)
        targets = targets.reject { |identifier, type| identifier == @self && type == TYPE.to_s }
        targets.each { |identifier, type| edges.add([identifier, type, via]) }
      end
    end

    # Extractor hooks: one resolution pass per run, in both modes.
    #
    # The full path edits the in-memory units before they are registered. The
    # incremental path re-reads every published `doc` unit and rewrites only
    # those whose edges or flags changed. Like a source-reference rewrite, that
    # is not an extraction: it leaves the unit's timestamp and Git facts alone.
    module Extraction
      private

      def enrich_doc_references_full
        docs = Array(@results[:docs])
        return if docs.empty?

        records = @results.values.flatten.map do |unit|
          doc_reference_record(unit.type, unit.identifier, SourceContributors.paths(unit))
        end
        resolver = Resolver.new(Registry.new(records))
        docs.each do |unit|
          edges, = resolve_doc_candidates(resolver, unit.identifier, unit.metadata, %i[mentions links kind text path
                                                                                       resolved])
          unit.dependencies = edges.map { |target, type, via| { type: type.to_sym, target: target, via: via.to_sym } }
        end
      end

      # Flags a document's candidates in place.
      #
      # @param keys [Array] the metadata keys, as symbols (a fresh unit) or strings (a published one)
      # @return [Array(Array, Integer)] the resolved edges and how many flags changed
      def resolve_doc_candidates(resolver, identifier, metadata, keys)
        mentions_key, links_key, kind, text, path, resolved = keys
        mentions = metadata.fetch(mentions_key)
        links = metadata.fetch(links_key)
        result = resolver.call(identifier: identifier, mentions: mentions.map do |mention|
          mention.values_at(kind, text)
        end,
                               links: links.map { |link| link[path] })
        changed = flag_doc_candidates(mentions, result.mentions, resolved) +
                  flag_doc_candidates(links, result.links, resolved)
        [result.edges, changed]
      end

      # @return [Integer] how many flags changed
      def flag_doc_candidates(candidates, flags, key)
        candidates.each_with_index.count do |candidate, index|
          next false if candidate[key] == flags[index]

          candidate[key] = flags[index]
          true
        end
      end

      # @param affected_types [Set<Symbol>] out-param of touched extractor keys
      # @return [Set<String>] identifiers of the documents rewritten
      def enrich_doc_references_incremental(affected_types)
        identifiers = @dependency_graph.units_of_type(TYPE).sort
        return Set.new if identifiers.empty?

        resolver = Resolver.new(Registry.new(doc_reference_graph_records))
        identifiers.filter_map { |identifier| refresh_doc_references(resolver, identifier, affected_types) }.to_set
      end

      # @return [String, nil] the identifier when the published unit was rewritten
      def refresh_doc_references(resolver, identifier, affected_types)
        key = self.class::TYPE_TO_EXTRACTOR_KEY.fetch(TYPE)
        path = payload_dir.join(key.to_s, collision_safe_filename(identifier))
        data = JSON.parse(AtomicFile.read(path))
        unless data.is_a?(Hash) && data['type'] == TYPE.to_s && data['identifier'] == identifier
          raise Woods::ExtractionError, "Documentation unit identity mismatch for #{identifier}"
        end

        edges, changed = resolve_doc_candidates(resolver, identifier, data.fetch('metadata'),
                                                %w[mentions links kind text path resolved])
        edges = edges.map { |target, type, via| { 'type' => type, 'target' => target, 'via' => via } }
        return nil if changed.zero? && data['dependencies'] == edges

        # The same rewrite a source-reference change takes: edges and reverse
        # edges move, the unit's timestamp and Git facts do not.
        rewrite_source_reference_edges({ data: data, path: path, extractor_key: key }, edges, affected_types)
        identifier
      end

      def doc_reference_graph_records
        @dependency_graph.to_h.fetch(:type_index).flat_map do |type, identifiers|
          identifiers.map do |identifier|
            node = @dependency_graph.node(identifier, type: type.to_sym)
            doc_reference_record(type, identifier, node[:source_paths] || Array(node[:file_path]))
          end
        end
      end

      def doc_reference_record(type, identifier, paths)
        root = File.expand_path(Rails.root.to_s)
        relative = paths.compact.filter_map do |path|
          absolute = File.expand_path(path.to_s, root)
          absolute.delete_prefix("#{root}/") if absolute.start_with?("#{root}/")
        end
        { type: type.to_s, identifier: identifier, paths: relative }
      end
    end
  end
end
