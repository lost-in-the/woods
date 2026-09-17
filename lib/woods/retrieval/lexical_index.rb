# frozen_string_literal: true

require 'json'
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
      K1 = 1.2
      B = 0.75
      Document = Struct.new(:key, :unit, :fields, keyword_init: true)
      private_constant :Document

      def initialize(metadata_store:)
        @documents = metadata_store.all_identifiers.sort.map do |key|
          unit = metadata_store.find(key)
          raise ArgumentError, "missing unit metadata for #{key.inspect}" unless unit.is_a?(Hash)

          unit = JSON.parse(JSON.generate(unit))
          fields = field_values(unit).transform_values { |value| tokenize(value).tally.freeze }.freeze
          Document.new(key: key.freeze, unit: deep_freeze(unit), fields: fields).freeze
        end.compact.freeze
        @averages = FIELD_WEIGHTS.to_h do |field, _|
          lengths = @documents.map { |doc| doc.fields.fetch(field).values.sum }
          [field, lengths.empty? ? 1.0 : [lengths.sum.fdiv(lengths.size), 1.0].max]
        end.freeze
        @frequencies = Hash.new(0)
        @documents.each { |doc| doc.fields.values.flat_map(&:keys).uniq.each { |term| @frequencies[term] += 1 } }
        @frequencies.freeze
      end

      def execute(query:, limit: 20, type_filter: nil, exclude_types: nil)
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
          normalization = K1 * (1 - B + (B * counts.values.sum / @averages.fetch(field)))
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
