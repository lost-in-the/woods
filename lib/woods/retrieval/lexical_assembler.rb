# frozen_string_literal: true

require_relative 'context_assembler'
require_relative 'lexical_index'

module Woods
  module Retrieval
    # Lexical context keeps matching evidence visible and charges every notice,
    # header and truncation marker to the same character-based token estimate.
    class LexicalAssembler
      # In full evidence a source may take at most an even share of what is
      # left among this many of the remaining candidates, so one long
      # top source cannot crowd out the rest. A short source leaves its unused
      # share to those after it.
      FAIR_SHARE_SOURCES = 4
      # Below this many characters a share is too small to show evidence; the
      # source then takes what is left, as one truncated source.
      MIN_SHARE_CHARS = 800

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
        candidates.each_with_index do |candidate, index|
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
          share = fair_share(remaining, header.length, candidates.size - index)
          truncated = source.length > share
          marker = "\n[Published evidence truncated; use lookup for the full unit.]"
          next if truncated && share <= marker.length

          context += header + (truncated ? source[0, share - marker.length] + marker : source)
          sources << { identifier: unit['identifier'], type: unit['type'], file_path: unit['file_path'],
                       score: candidate.score, matched_fields: candidate.matched_fields, truncated: truncated }
                     .merge(SourceContributors.attribution(unit))
        end
        body = context[notice.length..].to_s
        context = (count_notice(candidates.size, sources.size) + body)[0, budget * 4]
        AssembledContext.new(context: context, tokens_used: estimate_tokens(context), budget: budget,
                             sources: sources, sections: [:primary], skipped_missing_metadata: 0)
      end

      private

      # The characters this source may use: an even share, among the next
      # {FAIR_SHARE_SOURCES} candidates, of what is left once each of the
      # others has its header; all of it when that share would be too small
      # to read.
      def fair_share(remaining, header_length, candidates_left)
        sharing = [candidates_left, FAIR_SHARE_SOURCES].min
        return remaining if sharing <= 1

        share = (remaining - ((sharing - 1) * header_length)) / sharing
        share < MIN_SHARE_CHARS ? remaining : share
      end

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
        matched = candidate.matched_fields.filter_map do |field|
          field.delete_prefix('runtime:') if field.start_with?('runtime:')
        end
        "Published runtime metadata:\n#{runtime_metadata_text(values, matched)}\n\n#{source}"
      end

      # Runtime metadata as one line of JSON per entry, without empty values
      # and without framework callbacks that record no side effect. Pretty
      # printed in full, a model's callbacks alone (mostly Rails' own autosave
      # hooks, each with six empty side-effect lists) took its whole share of
      # the budget and left no room for its source. `lookup` returns the
      # complete metadata.
      #
      # A framework callback that one of the query's +matched+ runtime terms
      # names is kept: it is why the unit matched.
      def runtime_metadata_text(values, matched = [])
        values.filter_map do |key, value|
          value, omitted = app_callbacks(value, matched) if key == 'callbacks'
          value = compact_value(value)
          lines = if value.is_a?(Array) && value.any?(Hash)
                    ["#{key}:", *value.map { |item| "  #{JSON.generate(item)}" }]
                  elsif !blank_value?(value)
                    ["#{key}: #{JSON.generate(value)}"]
                  else
                    []
                  end
          if omitted.to_i.positive?
            lines << "#{key}:" if lines.empty?
            lines << "  (#{omitted} framework callback#{'s' unless omitted == 1} with no recorded side effects " \
                     'omitted; lookup lists them)'
          end
          lines.join("\n") unless lines.empty?
        end.join("\n")
      end

      # @return [Array(Object, Integer)] the callbacks worth showing and how many were left out
      def app_callbacks(callbacks, matched)
        return [callbacks, 0] unless callbacks.is_a?(Array)

        kept = callbacks.reject do |callback|
          callback.is_a?(Hash) && callback['origin'] == 'framework' &&
            blank_value?(compact_value(callback['side_effects'])) && !names_any?(callback, matched)
        end
        [kept, callbacks.size - kept.size]
      end

      # Whether the callback's own text holds one of the matched terms. The
      # index lowercases and splits names, so a term is a substring of the
      # name it came from.
      def names_any?(callback, terms)
        return false if terms.empty?

        text = JSON.generate(compact_value(callback)).downcase
        terms.any? { |term| text.include?(term) }
      end

      # Drops nil, empty strings, empty lists and empty hashes at every level.
      def compact_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), kept|
            item = compact_value(item)
            kept[key] = item unless blank_value?(item)
          end
        when Array
          value.map { |item| compact_value(item) }.reject { |item| blank_value?(item) }
        else
          value
        end
      end

      def blank_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
