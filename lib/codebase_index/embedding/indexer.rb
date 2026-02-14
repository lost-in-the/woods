# frozen_string_literal: true

require 'json'
require 'digest'

module CodebaseIndex
  module Embedding
    # Orchestrates the indexing pipeline: reads extracted units, prepares text,
    # generates embeddings, and stores vectors. Supports full and incremental
    # modes with checkpoint-based resumability.
    class Indexer
      def initialize(provider:, text_preparer:, vector_store:, output_dir:, batch_size: 32)
        @provider = provider
        @text_preparer = text_preparer
        @vector_store = vector_store
        @output_dir = output_dir
        @batch_size = batch_size
      end

      # Index all extracted units (full mode). Returns stats hash.
      #
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_all
        units = load_units
        process_units(units, incremental: false)
      end

      # Index only changed units (incremental mode). Returns stats hash.
      #
      # @return [Hash] Stats with :processed, :skipped, :errors counts
      def index_incremental
        units = load_units
        process_units(units, incremental: true)
      end

      private

      # @return [Array<Hash>] Parsed unit data from JSON files in output directory
      def load_units
        pattern = File.join(@output_dir, '**', '*.json')
        Dir.glob(pattern).filter_map do |path|
          next if File.basename(path) == 'checkpoint.json'

          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end
      end

      # @return [Hash] Processing stats (:processed, :skipped, :errors)
      def process_units(units, incremental:)
        checkpoint = incremental ? load_checkpoint : {}
        stats = { processed: 0, skipped: 0, errors: 0 }

        units.each_slice(@batch_size) do |batch|
          process_batch(batch, checkpoint, stats, incremental: incremental)
          save_checkpoint(checkpoint)
        end

        stats
      end

      # Process a single batch: filter unchanged, embed, and store.
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

      # Append embed items for a unit's prepared texts to the accumulator.
      def collect_embed_items(unit_data, items)
        texts = prepare_texts(unit_data)
        identifier = unit_data['identifier']

        texts.each_with_index do |text, idx|
          embed_id = texts.length > 1 ? "#{identifier}#chunk_#{idx}" : identifier
          items << { id: embed_id, text: text, unit_data: unit_data,
                     source_hash: unit_data['source_hash'], identifier: identifier }
        end
      end

      # @return [Array<String>] Prepared texts for embedding
      def prepare_texts(unit_data)
        unit = build_unit(unit_data)
        if unit.chunks&.any?
          @text_preparer.prepare_chunks(unit)
        else
          [@text_preparer.prepare(unit)]
        end
      end

      # @return [CodebaseIndex::ExtractedUnit] Unit built from parsed JSON data
      def build_unit(data)
        unit = ExtractedUnit.new(type: data['type']&.to_sym, identifier: data['identifier'],
                                 file_path: data['file_path'])
        populate_unit(unit, data)
      end

      # Populate optional attributes on an ExtractedUnit from parsed data.
      def populate_unit(unit, data)
        unit.namespace = data['namespace']
        unit.source_code = data['source_code']
        unit.dependencies = data['dependencies'] || []
        unit.chunks = (data['chunks'] || []).map { |c| c.transform_keys(&:to_sym) }
        unit
      end

      # Embed texts and store vectors, updating checkpoint and stats.
      def embed_and_store(items, checkpoint, stats)
        return if items.empty?

        vectors = @provider.embed_batch(items.map { |i| i[:text] })
        store_results(items, vectors, checkpoint, stats)
      rescue StandardError => e
        stats[:errors] += items.size
        raise CodebaseIndex::Error, "Embedding failed: #{e.message}"
      end

      # Store embedded vectors and update checkpoint tracking.
      def store_results(items, vectors, checkpoint, stats)
        items.each_with_index do |item, idx|
          metadata = { type: item[:unit_data]['type'], identifier: item[:identifier],
                       file_path: item[:unit_data]['file_path'] }
          @vector_store.store(item[:id], vectors[idx], metadata)
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
