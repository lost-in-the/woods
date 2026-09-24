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

        # Reserve the largest included count before selecting evidence. Replacing
        # it afterward can only shrink the text; do not refill or reorder sources.
        notice = count_notice(candidates.size, candidates.size)
        context = notice[0, budget * 4]
        sources = []
        candidates.each do |candidate|
          unit = candidate.metadata
          header = "\n\n## #{unit['identifier']} (#{unit['type']})\n#{SourceContributors.label(unit)}\n" \
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
                         evidence: selected.provenance }.merge(SourceContributors.attribution(unit))
            next
          end

          source = evidence_text(candidate)
          truncated = source.length > remaining
          marker = "\n[Published evidence truncated; use lookup for the full unit.]"
          next if truncated && remaining <= marker.length

          context += header + (truncated ? source[0, remaining - marker.length] + marker : source)
          sources << { identifier: unit['identifier'], type: unit['type'], file_path: unit['file_path'],
                       score: candidate.score, matched_fields: candidate.matched_fields, truncated: truncated }
                     .merge(SourceContributors.attribution(unit))
          break if truncated
        end
        body = context[notice.length..].to_s
        context = (count_notice(candidates.size, sources.size) + body)[0, budget * 4]
        AssembledContext.new(context: context, tokens_used: estimate_tokens(context), budget: budget,
                             sources: sources, sections: [:primary], skipped_missing_metadata: 0)
      end

      private

      def count_notice(candidates, included)
        text = "Mode: lexical (field-aware BM25; sources included: #{included}; " \
               "candidates considered: #{candidates}; candidate limit: #{LexicalIndex::DEFAULT_LIMIT}; " \
               'token counts estimated).'
        text += "\nNo lexical matches." if candidates.zero?
        text
      end

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
