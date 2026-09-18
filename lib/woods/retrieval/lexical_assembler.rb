# frozen_string_literal: true

require_relative 'context_assembler'
require_relative 'lexical_index'

module Woods
  module Retrieval
    # Lexical context keeps matching evidence visible and charges every notice,
    # header and truncation marker to the same character-based token estimate.
    class LexicalAssembler
      def estimate_tokens(text)
        (text.length / 4.0).ceil
      end

      def assemble(candidates:, budget:, evidence: 'full', query: nil, generation: nil, **)
        SourceEvidence.validate_mode!(evidence)
        raise ArgumentError, 'budget must be a positive Integer' unless budget.is_a?(Integer) && budget.positive?

        context = 'Mode: lexical (field-aware BM25; ranked top 20; token counts estimated).'
        context += "\nNo lexical matches." if candidates.empty?
        context = context[0, budget * 4]
        sources = []
        candidates.each do |candidate|
          unit = candidate.metadata
          header = "\n\n## #{unit['identifier']} (#{unit['type']})\nFile: #{unit['file_path']}\n" \
                   "Matched: #{candidate.matched_fields.join(', ')}\n\n"
          remaining = (budget * 4) - context.length - header.length
          next unless remaining.positive?

          if evidence != 'full'
            selected = SourceEvidence.new(unit: unit, query: query, generation: generation)
                                     .render(mode: evidence, budget: budget,
                                             counter: ->(text) { estimate_tokens(context + header + text) })
            next if selected.text.empty?

            context += header + selected.text
            sources << { identifier: unit['identifier'], type: unit['type'], file_path: unit['file_path'],
                         score: candidate.score, matched_fields: candidate.matched_fields,
                         evidence: selected.provenance }
            next
          end

          source = evidence_text(candidate)
          truncated = source.length > remaining
          marker = "\n[Published evidence truncated; use lookup for the full unit.]"
          next if truncated && remaining <= marker.length

          context += header + (truncated ? source[0, remaining - marker.length] + marker : source)
          sources << { identifier: unit['identifier'], type: unit['type'], file_path: unit['file_path'],
                       score: candidate.score, matched_fields: candidate.matched_fields, truncated: truncated }
          break if truncated
        end
        AssembledContext.new(context: context, tokens_used: estimate_tokens(context), budget: budget,
                             sources: sources, sections: [:primary], skipped_missing_metadata: 0)
      end

      private

      def evidence_text(candidate)
        unit = candidate.metadata
        source = unit['source_code'].to_s
        return source unless candidate.matched_fields.any? { |field| field.start_with?('runtime:') }

        metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
        values = LexicalIndex::RUNTIME_FIELDS.each_with_object({}) do |key, selected|
          value = metadata[key] || unit[key]
          selected[key] = value unless value.nil?
        end
        "Published runtime metadata:\n#{JSON.pretty_generate(values)}\n\n#{source}"
      end
    end
  end
end
