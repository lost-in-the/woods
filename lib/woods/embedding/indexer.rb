# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

require_relative '../extracted_unit'
require_relative '../chunking/semantic_chunker'

module Woods
  module Embedding
    # Orchestrates the indexing pipeline: reads extracted units, prepares text,
    # generates embeddings, and stores vectors. Supports full and incremental
    # modes with checkpoint-based resumability.
    #
    # When the vector store is an in-memory adapter (responds to +#each_entry+
    # and +#bulk_load+) and +output_dir+ is set, a successful {#index_all} run
    # also persists the stores to disk via the Snapshotter pair and atomically
    # flips the +dumps/latest+ pointer. Persistent backends (pgvector, Qdrant)
    # see zero behaviour change — no Snapshotter is invoked.
    class Indexer # rubocop:disable Metrics/ClassLength
      # @param chunker [Chunking::SemanticChunker, nil] Splits oversize units
      #   into semantically coherent chunks before embedding. +nil+ disables
      #   chunking — units go to the provider whole (useful in tests).
      # @param checkpoint_interval [Integer] Save checkpoint every N batches (default: 10)
      # @param metadata_store [#each_entry, #bulk_load, nil] Optional metadata store.
      #   When present alongside an in-memory vector store, both are persisted
      #   at the end of a successful {#index_all} run.
      # @param resolved_config [Woods::ResolvedConfig, nil] Captured config for
      #   +woods.json+ — written to +output_dir+ on {#index_all} completion.
      # @param dump_retention_count [Integer] Number of completed dump directories
      #   to keep under +output_dir/dumps/+. Older dumps are removed after a
      #   successful {#index_all} run (default: 3).
      def initialize(provider:, text_preparer:, vector_store:, output_dir:, # rubocop:disable Metrics/ParameterLists
                     chunker: Chunking::SemanticChunker.new,
                     batch_size: 32, checkpoint_interval: 10,
                     metadata_store: nil,
                     resolved_config: nil,
                     dump_retention_count: 3)
        @provider = provider
        @text_preparer = text_preparer
        @vector_store = vector_store
        @output_dir = output_dir
        @chunker = chunker
        @batch_size = batch_size
        @checkpoint_interval = checkpoint_interval
        @metadata_store = metadata_store
        @resolved_config = resolved_config
        @dump_retention_count = dump_retention_count
      end

      # Index all extracted units (full mode). Returns stats hash.
      #
      # When the vector store is an in-memory adapter, persists the embedded
      # vectors (and metadata, if a metadata store was provided) to disk under
      # +output_dir/dumps/<timestamp>/+ and atomically flips the +latest+
      # pointer. Writes +woods.json+ when +resolved_config+ was supplied.
      #
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_all
        stats = process_units(load_units, incremental: false)
        persist_snapshot if persistable?
        stats
      end

      # Index only changed units (incremental mode). Returns stats hash.
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_incremental
        process_units(load_units, incremental: true)
      end

      private

      def load_units
        Dir.glob(File.join(@output_dir, '**', '*.json')).filter_map do |path|
          next if File.basename(path) == 'checkpoint.json'

          data = JSON.parse(File.read(path))
          # Extraction output also contains index listings (_index.json arrays) and
          # summary files (manifest.json, dependency_graph.json, graph_analysis.json)
          # that live alongside per-unit JSON. Filter to the unit shape.
          data if data.is_a?(Hash) && data.key?('type') && data.key?('identifier')
        rescue JSON::ParserError
          nil
        end
      end

      def process_units(units, incremental:)
        checkpoint = incremental ? load_checkpoint : {}
        stats = { processed: 0, skipped: 0, errors: 0 }
        batch_count = 0

        units.each_slice(@batch_size) do |batch|
          process_batch(batch, checkpoint, stats, incremental: incremental)
          batch_count += 1
          save_checkpoint(checkpoint) if (batch_count % @checkpoint_interval).zero?
        end

        # Always save final checkpoint
        save_checkpoint(checkpoint)

        stats
      end

      def process_batch(batch, checkpoint, stats, incremental:)
        to_embed = batch.each_with_object([]) do |unit_data, items|
          persist_unit_metadata(unit_data)
          if incremental && checkpoint[unit_data['identifier']] == unit_data['source_hash']
            stats[:skipped] += 1
            next
          end
          collect_embed_items(unit_data, items)
        end

        embed_and_store(to_embed, checkpoint, stats)
      end

      # Persist a unit's metadata under its base identifier so retrieval can
      # resolve vector-search hits back to their unit data. Without this,
      # the metadata store is left empty at end of run — Snapshotter::Metadata
      # dumps a header with record_count: 0 and every MCP +codebase_retrieve+
      # call silently returns empty text, because ContextAssembler#find_batch
      # misses every candidate identifier. No-op when metadata_store is nil
      # (hosts that don't configure one). Stored under the base identifier,
      # not the chunk-suffixed id — chunks are an embedding-side concern only.
      def persist_unit_metadata(unit_data)
        return unless @metadata_store

        @metadata_store.store(unit_data['identifier'], unit_data)
      end

      def collect_embed_items(unit_data, items)
        texts = prepare_texts(unit_data)
        identifier = unit_data['identifier']

        texts.each_with_index do |text, idx|
          embed_id = texts.length > 1 ? "#{identifier}#chunk_#{idx}" : identifier
          items << { id: embed_id, text: text, unit_data: unit_data,
                     source_hash: unit_data['source_hash'], identifier: identifier }
        end
      end

      def prepare_texts(unit_data)
        unit = build_unit(unit_data)
        apply_chunking(unit) if @chunker && unit.chunks.empty? && needs_chunking?(unit)
        # Extraction may have emitted chunks larger than the provider's
        # budget (rails_source in particular). Enforce the ceiling on
        # whatever chunks we have before handing off to the provider.
        @chunker&.enforce_chunk_limits!(unit) if unit.chunks.any?
        unit.chunks.any? ? @text_preparer.prepare_chunks(unit) : [@text_preparer.prepare(unit)]
      end

      # Does this unit exceed the embedding provider's single-input
      # budget? Returns false when the provider reports no budget, when
      # the TextPreparer has no calibrated chars-per-token ratio, or when
      # the unit's source fits.
      #
      # When the configured chunker carries a real tokenizer
      # (Embedding::TokenCounter) we also consult it — dense Ruby source
      # tokenizes hotter than chars/token averages suggest, and Ollama
      # rejects over-budget input outright (see ollama/ollama#14186).
      def needs_chunking?(unit)
        budget_tokens = @provider.respond_to?(:max_input_tokens) ? @provider.max_input_tokens : nil
        return false if budget_tokens.nil?
        return false unless @text_preparer.respond_to?(:chars_per_token)

        source = unit.source_code || ''
        return true if chunker_token_oversize?(source)

        # Subtract a small prefix allowance — the TextPreparer adds a few
        # hundred characters of context header ([type] identifier / file /
        # dependencies) that count toward the budget too.
        char_budget = (budget_tokens * @text_preparer.chars_per_token).floor - PREFIX_CHAR_ALLOWANCE
        char_budget.positive? && source.length > char_budget
      end

      # Ask the chunker's real tokenizer whether +source+ already exceeds
      # the token budget. Returns false when the chunker wasn't built with
      # one (e.g., OpenAI path), leaving the char-based check in charge.
      def chunker_token_oversize?(source)
        return false unless @chunker&.token_counter && @chunker.max_tokens

        @chunker.token_counter.count(source) > @chunker.max_tokens
      end

      # Populate unit.chunks from the configured chunker. The chunker's
      # own +max_chars+ safety net is what guarantees each chunk fits,
      # so we pass the same char budget through here.
      def apply_chunking(unit)
        unit.chunks = @chunker.chunk(unit).map do |chunk|
          { content: chunk.content, chunk_type: chunk.chunk_type }
        end
      end

      def build_unit(data)
        unit = ExtractedUnit.new(type: data['type']&.to_sym, identifier: data['identifier'],
                                 file_path: data['file_path'])
        unit.namespace = data['namespace']
        unit.source_code = data['source_code']
        unit.dependencies = data['dependencies'] || []
        unit.chunks = (data['chunks'] || []).map { |c| c.transform_keys(&:to_sym) }
        unit
      end

      # Character budget reserved for the TextPreparer context prefix
      # ("[type] id / namespace / file / dependencies: …"). Typical
      # prefixes run ~200–400 chars; 512 gives room to spare.
      PREFIX_CHAR_ALLOWANCE = 512
      private_constant :PREFIX_CHAR_ALLOWANCE

      def embed_and_store(items, checkpoint, stats)
        return if items.empty?

        vectors = @provider.embed_batch(items.map { |i| i[:text] })
        store_vectors(items, vectors, checkpoint, stats)
      rescue StandardError => e
        stats[:errors] += items.size
        raise Woods::Error, "Embedding failed: #{e.message}"
      end

      def store_vectors(items, vectors, checkpoint, stats)
        entries = items.each_with_index.map do |item, idx|
          { id: item[:id], vector: vectors[idx],
            metadata: { type: item[:unit_data]['type'], identifier: item[:identifier],
                        file_path: item[:unit_data]['file_path'] } }
        end

        @vector_store.store_batch(entries)

        items.each do |item|
          checkpoint[item[:identifier]] = item[:source_hash]
          stats[:processed] += 1
        end
      end

      def load_checkpoint
        path = File.join(@output_dir, 'checkpoint.json')
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def save_checkpoint(checkpoint)
        File.write(File.join(@output_dir, 'checkpoint.json'), JSON.generate(checkpoint))
      end

      # Returns true when the vector store is an in-memory adapter that supports
      # the persistence seam (+#each_entry+ / +#bulk_load+) and output_dir is set.
      # Persistent backends (pgvector, Qdrant) never respond to +#each_entry+.
      def persistable?
        @output_dir &&
          @vector_store.respond_to?(:each_entry) &&
          @vector_store.respond_to?(:bulk_load)
      end

      # Persist stores to a timestamped dump directory, write +woods.json+,
      # flip the +latest+ pointer, then prune old dumps.
      def persist_snapshot
        require_relative '../index_artifact'
        require_relative '../storage/snapshotter'

        artifact = IndexArtifact.new(@output_dir)
        dump_dir = artifact.new_dump_dir

        Storage::Snapshotter::Vector.dump(@vector_store, artifact, dump_dir)

        if @metadata_store.respond_to?(:each_entry) && @metadata_store.respond_to?(:bulk_load)
          Storage::Snapshotter::Metadata.dump(@metadata_store, artifact, dump_dir)
        end

        artifact.write_config(@resolved_config) if @resolved_config

        artifact.promote(dump_dir)

        prune_old_dumps(artifact)
      end

      # Remove old dump directories beyond the retention window.
      #
      # Keeps the +@dump_retention_count+ most-recently-created directories
      # (sorted by name, which is a UTC timestamp so lexicographic order equals
      # chronological order). The current +latest+ directory is always kept.
      def prune_old_dumps(artifact)
        return if @dump_retention_count.nil? || @dump_retention_count <= 0

        dumps_root = artifact.dumps_root
        return unless dumps_root.exist?

        dirs = sorted_dump_dirs(dumps_root)
        excess = dirs.length - @dump_retention_count
        dirs.first(excess).each { |dir| FileUtils.rm_rf(dir) } if excess.positive?
      end

      def sorted_dump_dirs(dumps_root)
        dumps_root.children
                  .select(&:directory?)
                  .sort_by(&:basename)
                  .map(&:to_s)
      end
    end
  end
end
