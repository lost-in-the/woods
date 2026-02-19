# frozen_string_literal: true

require 'json'

module CodebaseIndex
  module SessionTracer
    # Value object representing an assembled session flow trace.
    #
    # Contains a two-level structure:
    # - **Timeline** — ordered steps with unit_refs and side_effects (lightweight)
    # - **Context pool** — deduplicated ExtractedUnit data (heavy, included once each)
    #
    # Follows the FlowDocument pattern for serialization and rendering.
    #
    # @example
    #   doc = SessionFlowDocument.new(
    #     session_id: "abc123",
    #     steps: [...],
    #     context_pool: { "OrdersController" => { ... } },
    #     generated_at: Time.now.utc.iso8601
    #   )
    #   doc.to_h         # => JSON-serializable Hash
    #   doc.to_markdown   # => human-readable document
    #   doc.to_context    # => LLM XML format
    #
    # rubocop:disable Metrics/ClassLength
    class SessionFlowDocument
      attr_reader :session_id, :steps, :context_pool, :side_effects,
                  :dependency_map, :token_count, :generated_at

      # @param session_id [String] The session identifier
      # @param steps [Array<Hash>] Ordered timeline steps
      # @param context_pool [Hash<String, Hash>] Deduplicated unit data keyed by identifier
      # @param side_effects [Array<Hash>] Async side effects (jobs, mailers)
      # @param dependency_map [Hash<String, Array<String>>] Unit -> dependency identifiers
      # @param token_count [Integer] Estimated total tokens
      # @param generated_at [String, nil] ISO8601 timestamp (defaults to now)
      # rubocop:disable Metrics/ParameterLists
      def initialize(session_id:, steps: [], context_pool: {}, side_effects: [],
                     dependency_map: {}, token_count: 0, generated_at: nil)
        @session_id = session_id
        @steps = steps
        @context_pool = context_pool
        @side_effects = side_effects
        @dependency_map = dependency_map
        @token_count = token_count
        @generated_at = generated_at || Time.now.utc.iso8601
      end
      # rubocop:enable Metrics/ParameterLists

      # Serialize to a JSON-compatible Hash.
      #
      # @return [Hash]
      def to_h
        {
          session_id: @session_id,
          generated_at: @generated_at,
          token_count: @token_count,
          steps: @steps,
          context_pool: @context_pool,
          side_effects: @side_effects,
          dependency_map: @dependency_map
        }
      end

      # Reconstruct from a serialized Hash.
      #
      # Handles both symbol and string keys for JSON round-trip compatibility.
      #
      # @param data [Hash] Previously serialized document data
      # @return [SessionFlowDocument]
      def self.from_h(data)
        data = deep_symbolize_keys(data)

        new(
          session_id: data[:session_id],
          steps: data[:steps] || [],
          context_pool: data[:context_pool] || {},
          side_effects: data[:side_effects] || [],
          dependency_map: data[:dependency_map] || {},
          token_count: data[:token_count] || 0,
          generated_at: data[:generated_at]
        )
      end

      # Render as human-readable Markdown.
      #
      # @return [String]
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def to_markdown
        lines = []
        lines << "## Session: #{@session_id}"
        lines << "_Generated at #{@generated_at} | #{@steps.size} requests | ~#{@token_count} tokens_"
        lines << ''

        # Timeline
        lines << '### Timeline'
        lines << ''
        @steps.each_with_index do |step, idx|
          status = step[:status] || '?'
          duration = step[:duration_ms] ? " (#{step[:duration_ms]}ms)" : ''
          entry = "#{idx + 1}. #{step[:method]} #{step[:path]} → " \
                  "#{step[:controller]}##{step[:action]} [#{status}]#{duration}"
          lines << entry
        end
        lines << ''

        # Side effects
        if @side_effects.any?
          lines << '### Side Effects'
          lines << ''
          @side_effects.each do |effect|
            lines << "- #{effect[:type]}: #{effect[:identifier]} (triggered by #{effect[:trigger_step]})"
          end
          lines << ''
        end

        # Context pool
        if @context_pool.any?
          lines << '### Code Units'
          lines << ''
          @context_pool.each do |identifier, unit|
            type = unit[:type] || 'unknown'
            file_path = unit[:file_path]
            lines << "#### #{identifier} (#{type})"
            lines << "_#{file_path}_" if file_path
            lines << ''
            next unless unit[:source_code]

            lines << '```ruby'
            lines << unit[:source_code]
            lines << '```'
            lines << ''
          end
        end

        # Dependencies
        if @dependency_map.any?
          lines << '### Dependencies'
          lines << ''
          @dependency_map.each do |unit_id, deps|
            lines << "- #{unit_id} → #{deps.join(', ')}"
          end
          lines << ''
        end

        lines.join("\n")
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # Render as LLM-consumable XML context.
      #
      # Follows the format from docs/CONTEXT_AND_CHUNKING.md.
      #
      # @return [String]
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def to_context
        lines = []
        header = "<session_context session_id=\"#{@session_id}\" requests=\"#{@steps.size}\" " \
                 "tokens=\"#{@token_count}\" units=\"#{@context_pool.size}\">"
        lines << header

        # Timeline
        lines << '<session_timeline>'
        @steps.each_with_index do |step, idx|
          status = step[:status] || '?'
          duration = step[:duration_ms] ? ", #{step[:duration_ms]}ms" : ''
          entry = "#{idx + 1}. #{step[:method]} #{step[:path]} → " \
                  "#{step[:controller]}##{step[:action]} (#{status}#{duration})"
          lines << entry
        end
        lines << '</session_timeline>'

        # Units
        @context_pool.each do |identifier, unit|
          type = unit[:type] || 'unknown'
          file_path = unit[:file_path] || 'unknown'
          lines << %(<unit identifier="#{identifier}" type="#{type}" file="#{file_path}">)
          lines << (unit[:source_code] || '# source not available')
          lines << '</unit>'
        end

        # Side effects
        if @side_effects.any?
          lines << '<side_effects>'
          @side_effects.each do |effect|
            lines << "#{effect[:identifier]} (triggered by #{effect[:trigger_step]}, #{effect[:type]})"
          end
          lines << '</side_effects>'
        end

        # Dependencies
        if @dependency_map.any?
          lines << '<dependencies>'
          @dependency_map.each do |unit_id, deps|
            lines << "#{unit_id} → #{deps.join(', ')}"
          end
          lines << '</dependencies>'
        end

        lines << '</session_context>'
        lines.join("\n")
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # @api private
      def self.deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), result|
            result[key.to_sym] = deep_symbolize_keys(value)
          end
        when Array
          obj.map { |item| deep_symbolize_keys(item) }
        else
          obj
        end
      end
      private_class_method :deep_symbolize_keys
    end
    # rubocop:enable Metrics/ClassLength
  end
end
