# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'query_classifier'
require_relative 'search_executor'

module Woods
  module Retrieval
    # Immutable field-aware lexical snapshot. Only published unit values enter
    # the vocabulary; bookkeeping and arbitrary JSON keys cannot become hits.
    class LexicalIndex
      FIELD_WEIGHTS = { 'identifier' => 4.0, 'file_path' => 2.0, 'source_code' => 1.0, 'runtime' => 2.0 }.freeze
      RUNTIME_FIELDS = %w[callbacks associations validations scopes concerns included_modules
                          methods instance_methods class_methods actions routes columns table_name
                          description purpose dependencies].freeze
      DEFAULT_LIMIT = 20
      K1 = 1.2
      B = 0.75
      # +terms+ is the document's distinct vocabulary and +lengths+ its
      # per-field token totals, tallied once at build so a view's statistics
      # come from the tallies, not from the token counts again.
      Document = Struct.new(:key, :unit, :fields, :terms, :lengths, keyword_init: true)
      private_constant :Document

      # The indexed units by key: immutable, shared with every candidate's
      # +metadata+ and with the scope corpus the pipeline keeps (F6 step 2).
      #
      # @return [Hash{String => Hash}] in key order
      attr_reader :units

      # @param metadata_store [MetadataStore::Interface] the records to index
      # @param documents [Array<Document>, nil] an already-built, immutable
      #   document set to index instead (see {#restricted_to})
      # @param statistics [Array(Hash, Hash), nil] per-field length totals
      #   and document frequencies already known for +documents+
      def initialize(metadata_store: nil, documents: nil, statistics: nil)
        @documents = (documents || build_documents(metadata_store)).freeze
        @units = @documents.to_h { |doc| [doc.key, doc.unit] }.freeze
        @totals, @frequencies = statistics || tally(@documents)
        @totals.freeze
        @frequencies.freeze
        @averages = @totals.to_h do |field, total|
          [field, @documents.empty? ? 1.0 : [total.fdiv(@documents.size), 1.0].max]
        end.freeze
      end

      # A view over the eligible subset of this index's documents, answering
      # exactly what an index built over those records would: the BM25
      # statistics (field-length averages, document frequencies) are
      # recomputed over the subset and the documents, immutable, are shared,
      # so nothing is re-read or re-tokenised (F6 step 2). A scoped request
      # used to build a whole index over the eligible records every time.
      # When the subset is most of the index, the statistics come from
      # subtracting the excluded documents' tallies from this index's own,
      # so a near-whole scope costs the exclusions, not the whole corpus.
      #
      # @param keys [Enumerable<String>] eligible document keys
      # @return [LexicalIndex]
      def restricted_to(keys)
        allowed = keys.to_set
        documents, excluded = @documents.partition { |doc| allowed.include?(doc.key) }
        statistics = subtract(excluded) if excluded.size < documents.size
        self.class.new(documents: documents, statistics: statistics)
      end

      def execute(query:, limit: DEFAULT_LIMIT, type_filter: nil, exclude_types: nil)
        terms = tokenize(query).uniq
        candidates = @documents.filter_map do |doc|
          next unless eligible?(doc.unit, type_filter, exclude_types)

          score, fields = score_document(doc, terms)
          exact = doc.unit['identifier'].to_s.casecmp?(query.strip)
          score += 1.0 if exact
          fields << 'identifier:exact' if exact
          next unless score.positive?

          SearchExecutor::Candidate.new(identifier: doc.key, score: score, source: :lexical,
                                        metadata: doc.unit, matched_fields: fields.sort)
        end
        candidates.sort_by! do |candidate|
          [candidate.matched_fields.include?('identifier:exact') ? 0 : 1, -candidate.score, candidate.identifier]
        end
        SearchExecutor::ExecutionResult.new(candidates: candidates.first(limit), strategy: :lexical, query: query)
      end

      private

      def build_documents(metadata_store)
        metadata_store.all_identifiers.sort.map do |key|
          unit = metadata_store.find(key)
          raise ArgumentError, "missing unit metadata for #{key.inspect}" unless unit.is_a?(Hash)

          unit = JSON.parse(JSON.generate(unit))
          fields = field_values(unit).transform_values { |value| tokenize(value).tally.freeze }.freeze
          Document.new(key: key.freeze, unit: deep_freeze(unit), fields: fields,
                       terms: fields.values.flat_map(&:keys).uniq.freeze,
                       lengths: fields.transform_values { |counts| counts.values.sum }.freeze).freeze
        end
      end

      # Per-field length totals and document frequencies over +documents+.
      #
      # @return [Array(Hash, Hash)]
      def tally(documents)
        totals = FIELD_WEIGHTS.to_h { |field, _| [field, 0] }
        frequencies = Hash.new(0)
        documents.each do |doc|
          doc.lengths.each { |field, length| totals[field] += length }
          doc.terms.each { |term| frequencies[term] += 1 }
        end
        [totals, frequencies]
      end

      # This index's statistics less the +excluded+ documents' tallies. The
      # totals are integer sums, so the result equals a fresh tally over the
      # remaining documents exactly; a term left with no document is dropped.
      def subtract(excluded)
        totals = @totals.dup
        frequencies = @frequencies.dup
        excluded.each do |doc|
          doc.lengths.each { |field, length| totals[field] -= length }
          doc.terms.each { |term| frequencies.delete(term) if (frequencies[term] -= 1).zero? }
        end
        [totals, frequencies]
      end

      def tokenize(value)
        value.to_s.gsub(/(\p{Ll}|\d)(\p{Lu})/u, '\1 \2')
             .gsub(/(\p{Lu})(\p{Lu}\p{Ll})/u, '\1 \2').downcase
             .scan(/[\p{L}\p{N}]+/u).reject { |term| QueryClassifier::STOP_WORDS.include?(term) }
      end

      def field_values(unit)
        metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
        runtime = RUNTIME_FIELDS.filter_map { |key| metadata[key] || unit[key] }
        { 'identifier' => unit['identifier'], 'file_path' => unit['file_path'],
          'source_code' => unit['source_code'], 'runtime' => values_text(runtime) }
      end

      def values_text(value)
        case value
        when Hash then value.values.map { |child| values_text(child) }.join(' ')
        when Array then value.map { |child| values_text(child) }.join(' ')
        when String, Symbol, Numeric then value.to_s
        else ''
        end
      end

      def eligible?(unit, allowed, excluded)
        return allowed.map(&:to_s).include?(unit['type']) if allowed && !allowed.empty?

        !Array(excluded).map(&:to_s).include?(unit['type'])
      end

      def score_document(doc, terms)
        fields = []
        score = FIELD_WEIGHTS.sum do |field, weight|
          counts = doc.fields.fetch(field)
          normalization = K1 * (1 - B + (B * doc.lengths.fetch(field) / @averages.fetch(field)))
          terms.sum do |term|
            frequency = counts.fetch(term, 0)
            next 0.0 if frequency.zero?

            fields << "#{field}:#{term}"
            document_frequency = @frequencies.fetch(term)
            idf = Math.log(1 + ((@documents.size - document_frequency + 0.5) / (document_frequency + 0.5)))
            weight * idf * frequency * (K1 + 1) / (frequency + normalization)
          end
        end
        [score, fields]
      end

      def deep_freeze(value)
        case value
        when Hash then value.each do |key, child|
          key.freeze
          deep_freeze(child)
        end
        when Array then value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
