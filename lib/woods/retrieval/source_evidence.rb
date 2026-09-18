# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../ast/parser'
require_relative 'lexical_index'

module Woods
  module Retrieval
    # Selects complete spans from published unit bytes, never from host files.
    # Published coordinates deliberately do not claim physical source locations:
    # extractors may synthesize headers or inline commented concern bodies.
    class SourceEvidence
      MODES = %w[full compact outline].freeze
      Result = Struct.new(:text, :provenance, keyword_init: true)
      Span = Struct.new(:kind, :name, :lexical_owner, :receiver, :start_byte, :end_byte, :start_line, :end_line,
                        keyword_init: true)
      private_constant :Span

      def self.validate_mode!(mode)
        return mode if MODES.include?(mode)

        raise ArgumentError, 'evidence must be full, compact, or outline'
      end

      def initialize(unit:, query: nil, generation: nil, parser: Ast::Parser.new)
        @unit = unit
        @source = field(:source_code).to_s
        @query = terms(query)
        @generation = generation
        @parser = parser
      end

      # The caller's counter includes the same tokenizer/estimate used by its
      # response budget. No selected definition or metadata value is cut in half.
      def render(mode:, budget:, counter:)
        self.class.validate_mode!(mode)
        raise ArgumentError, 'budget must be a positive Integer' unless budget.is_a?(Integer) && budget.positive?
        raise ArgumentError, 'compact evidence requires compact or outline mode' if mode == 'full'

        spans = source_spans
        selected = []
        metadata = []
        ordered = spans.sort_by { |span| [-relevance(span), span.start_byte] }
        relevant, other = ordered.partition { |span| @query.empty? || relevance(span).positive? }
        relevant.each do |span|
          trial = selected + [span]
          selected = trial if counter.call(format_evidence(mode, trial, metadata, spans.size)) <= budget
        end
        runtime_records.each do |record|
          trial = metadata + [record]
          metadata = trial if counter.call(format_evidence(mode, selected, trial, spans.size)) <= budget
        end
        other.each do |span|
          trial = selected + [span]
          selected = trial if counter.call(format_evidence(mode, trial, metadata, spans.size)) <= budget
        end
        text = format_evidence(mode, selected, metadata, spans.size)
        return Result.new(text: '', provenance: provenance(mode, [], [], spans)) if counter.call(text) > budget

        Result.new(text: text, provenance: provenance(mode, selected, metadata, spans))
      end

      private

      def field(key)
        @unit[key] || @unit[key.to_s]
      end

      def source_spans
        return [] if @source.empty?

        spans = []
        walk(@parser.parse(@source), nil, spans)
        spans.concat(concern_spans)
        return spans unless spans.empty?

        [Span.new(kind: 'published_source', name: field(:identifier), lexical_owner: nil,
                  start_byte: 0, end_byte: @source.bytesize, start_line: 1, end_line: @source.lines.size)]
      rescue Woods::ExtractionError
        # Non-Ruby or legacy synthesized source remains available as one whole
        # published span. An unavailable boundary is never guessed with regex.
        [Span.new(kind: 'unparsed_source', name: field(:identifier), lexical_owner: nil,
                  start_byte: 0, end_byte: @source.bytesize, start_line: 1, end_line: @source.lines.size)]
      end

      def walk(node, owner, spans, singleton_scope: false)
        return unless node.is_a?(Ast::Node)

        if %i[class module].include?(node.type)
          name = node.method_name.to_s
          owner = name.start_with?('::') ? name.delete_prefix('::') : [owner, name].compact.join('::')
        elsif %i[def defs].include?(node.type)
          if node.start_byte && node.end_byte
            kind = if singleton_scope
                     'singleton_body_method'
                   else
                     (node.type == :def ? 'instance_method' : 'singleton_method')
                   end
            spans << Span.new(kind: kind,
                              name: node.method_name, lexical_owner: owner, receiver: node.receiver,
                              start_byte: node.start_byte,
                              end_byte: node.end_byte, start_line: node.line, end_line: node.end_line)
          end
          return # Nested definitions/blocks are already covered by the complete outer method.
        end
        node.children&.each do |child|
          walk(child, owner, spans, singleton_scope: singleton_scope || node.type == :sclass)
        end
      end

      # These are Woods' published display blocks, not physical concern source.
      # Require matching published metadata and delimiters; preserve every byte,
      # including comment prefixes, instead of reconstructing executable Ruby.
      def concern_spans
        metadata = field(:metadata) || {}
        Array(metadata['inlined_concerns'] || metadata[:inlined_concerns]).filter_map do |name|
          escaped = Regexp.escape(name.to_s)
          pattern = /^# │ Included from: #{escaped}[^\S\r\n]*│\r?\n.*?^# ─+ End #{escaped} ─+\r?$/m
          match = pattern.match(@source)
          next unless match

          start_byte = @source[0...match.begin(0)].bytesize
          end_byte = @source[0...match.end(0)].bytesize
          Span.new(kind: 'inlined_concern_display', name: name, lexical_owner: name,
                   start_byte: start_byte, end_byte: end_byte,
                   start_line: @source.byteslice(0, start_byte).count("\n") + 1,
                   end_line: @source.byteslice(0, end_byte).count("\n") + 1)
        end
      end

      def terms(value)
        value.to_s.gsub(/(\p{Ll}|\d)(\p{Lu})/u, '\1 \2').downcase.scan(/[\p{L}\p{N}]+/u)
             .reject { |term| QueryClassifier::STOP_WORDS.include?(term) }.uniq
      end

      def relevance(span)
        ((terms(span.name) & @query).size * 4) + (terms(span_text(span)) & @query).size
      end

      def span_text(span)
        @source.byteslice(span.start_byte...span.end_byte)
      end

      def runtime_records
        metadata = field(:metadata)
        return [] unless metadata.is_a?(Hash)

        LexicalIndex::RUNTIME_FIELDS.filter_map do |key|
          value = metadata[key] || metadata[key.to_sym]
          next if value.nil?

          record = [key, value]
          record if @query.empty? || (terms(JSON.generate(record)) & @query).any?
        end
      end

      def format_evidence(mode, selected, metadata, total)
        parts = ["Evidence: #{mode}; published-unit coordinates (physical location unavailable).",
                 "Unit: #{field(:type)}:#{field(:identifier)}; path: #{field(:file_path)}",
                 "Source SHA256: #{Digest::SHA256.hexdigest(@source)}",
                 "Generation: #{@generation || 'unavailable (not recorded by this metadata store)'}"]
        selected.each do |span|
          label = "#{span.kind} #{span.lexical_owner} #{span.name}; published lines #{span.start_line}-#{span.end_line}"
          parts << (mode == 'outline' ? label : "#{label}\n```ruby\n#{span_text(span)}\n```")
        end
        parts << "Published runtime metadata:\n#{JSON.generate(metadata.to_h)}" unless metadata.empty?
        parts << "Omitted: #{total - selected.size} source spans; remaining source/metadata not reproduced. " \
                 'Use lookup with evidence: full for the complete published unit.'
        parts.join("\n\n")
      end

      def provenance(mode, selected, metadata, all)
        { mode: mode, owner: { identifier: field(:identifier), type: field(:type) },
          coordinate_system: 'published_unit', source_sha256: Digest::SHA256.hexdigest(@source),
          source_path: field(:file_path), physical_location: nil,
          physical_location_reason: 'published unit may contain synthesized or inlined source',
          generation: @generation, generation_status: @generation ? 'recorded' : 'unavailable',
          spans: selected.map { |span| span.to_h.merge(sha256: Digest::SHA256.hexdigest(span_text(span))) },
          omitted_spans: all.size - selected.size, runtime_fields: metadata.map(&:first),
          source_complete: false, full_evidence: { tool: 'lookup', evidence: 'full',
                                                   identifier: field(:identifier), type: field(:type),
                                                   source_sha256: Digest::SHA256.hexdigest(@source) } }
      end
    end
  end
end
