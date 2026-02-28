# frozen_string_literal: true

require 'json'
require 'digest'

module CodebaseIndex
  module Embedding
    # Orchestrates the indexing pipeline: reads extracted units, prepares text,
    # generates embeddings, and stores vectors. Supports full and incremental
    # modes with checkpoint-based resumability.
    class Indexer
      # @param checkpoint_interval [Integer] Save checkpoint every N batches (default: 10)
      def initialize(provider:, text_preparer:, vector_store:, output_dir:, batch_size: 32, checkpoint_interval: 10) # rubocop:disable Metrics/ParameterLists
        @provider = provider
        @text_preparer = text_preparer
        @vector_store = vector_store
        @output_dir = output_dir
        @batch_size = batch_size
        @checkpoint_interval = checkpoint_interval
      end

      # Index all extracted units (full mode). Returns stats hash.
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_all
        process_units(load_units, incremental: false)
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

          JSON.parse(File.read(path))
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
          if incremental && checkpoint[unit_data['identifier']] == unit_data['source_hash']
            stats[:skipped] += 1
            next
          end
          collect_embed_items(unit_data, items)
        end

        embed_and_store(to_embed, checkpoint, stats)
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
        unit.chunks&.any? ? @text_preparer.prepare_chunks(unit) : [@text_preparer.prepare(unit)]
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

      def embed_and_store(items, checkpoint, stats)
        return if items.empty?

        vectors = @provider.embed_batch(items.map { |i| i[:text] })
        store_vectors(items, vectors, checkpoint, stats)
      rescue StandardError => e
        stats[:errors] += items.size
        stats[:error_messages] ||= []
        stats[:error_messages] << e.message
        raise CodebaseIndex::Error, "Embedding failed: #{e.message}"
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
    end
  end
end
