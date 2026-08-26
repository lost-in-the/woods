# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../token_utils'
require_relative 'session_flow_document'

module Woods
  module SessionTracer
    # Assembles a context tree from captured session requests against the extracted index.
    #
    # Does NOT require Rails — reads from a store + on-disk extracted index.
    #
    # Algorithm:
    # 1. Load requests from store for session_id
    # 2. For each request, resolve "Controller#action" via IndexReader
    # 3. Expand dependencies via DependencyGraph — filter :job/:mailer as async side effects
    # 4. Deduplicate units across steps (include source once, reference by identifier)
    # 5. Token budget allocation with priority-based truncation
    # 6. Build SessionFlowDocument
    #
    # @example
    #   assembler = SessionFlowAssembler.new(store: store, reader: reader)
    #   doc = assembler.assemble("abc123", budget: 8000, depth: 1)
    #   puts doc.to_context
    #
    # rubocop:disable-next Metrics/ClassLength
    class SessionFlowAssembler
      ASYNC_TYPES = %w[job mailer].to_set.freeze
      RENDER_BUDGET_ATTEMPTS = 3

      # @param store [Store] Session trace store
      # @param reader [MCP::IndexReader] Index reader for unit lookups
      def initialize(store:, reader:)
        @store = store
        @reader = reader
      end

      # Assemble a context tree for a session.
      #
      # @param session_id [String] The session to assemble
      # @param budget [Integer] Maximum token budget (default: 8000)
      # @param depth [Integer] Expansion depth (0=metadata only, 1=direct deps, 2+=full flow)
      # @return [SessionFlowDocument] The assembled document
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def assemble(session_id, budget: 8000, depth: 1)
        requests = @store.read(session_id)
        return empty_document(session_id) if requests.empty?

        steps = []
        context_pool = {}
        side_effects = []
        dependency_map = {}
        seen_units = Set.new

        requests.each_with_index do |req, idx|
          step = build_step(req, idx)
          steps << step

          next if depth.zero?

          controller_id = req['controller']
          next unless controller_id

          # Resolve controller unit
          unit = @reader.find_unit(controller_id)
          if unit && !seen_units.include?(controller_id)
            seen_units.add(controller_id)
            context_pool[controller_id] = unit_summary(unit)
          end
          step[:unit_refs] = [controller_id].compact

          # Expand dependencies
          next unless unit

          deps = resolve_dependencies(controller_id, seen_units, context_pool,
                                      side_effects, step, dependency_map, depth)
          step[:unit_refs].concat(deps)
        end

        # Apply token budget against the rendered output, not just the pool
        apply_budget(context_pool, budget)
        parts = { session_id: session_id, steps: steps, context_pool: context_pool,
                  side_effects: side_effects, dependency_map: dependency_map }
        budgeted_document(parts, budget)
      end

      private

      # Build a timeline step from a request record.
      #
      # @param req [Hash] Request data from store
      # @param index [Integer] Step index
      # @return [Hash] Step hash
      def build_step(req, index)
        {
          index: index,
          method: req['method'],
          path: req['path'],
          controller: req['controller'],
          action: req['action'],
          status: req['status'],
          duration_ms: req['duration_ms'],
          unit_refs: [],
          side_effects: []
        }
      end

      # Resolve dependencies for a unit, separating sync deps from async side effects.
      #
      # @return [Array<String>] Non-async dependency identifiers added
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
      def resolve_dependencies(unit_id, seen_units, context_pool,
                               side_effects, step, dependency_map, depth)
        graph = @reader.dependency_graph
        dep_ids = graph.dependencies_of(unit_id)
        added = []

        dep_ids.each do |dep_id|
          dep_unit = @reader.find_unit(dep_id)
          next unless dep_unit

          dep_type = dep_unit['type']&.to_s

          if ASYNC_TYPES.include?(dep_type)
            effect = {
              type: dep_type.to_sym,
              identifier: dep_id,
              trigger_step: "#{step[:controller]}##{step[:action]}"
            }
            side_effects << effect
            step[:side_effects] << effect
          else
            unless seen_units.include?(dep_id)
              seen_units.add(dep_id)
              context_pool[dep_id] = unit_summary(dep_unit)
              added << dep_id

              # Depth 2+: expand transitive dependencies
              expand_transitive(dep_id, seen_units, context_pool, dependency_map, depth - 1) if depth >= 2
            end
          end
        end

        # Record dependency map for this unit
        all_deps = dep_ids.select { |id| @reader.find_unit(id) }
        dependency_map[unit_id] = all_deps if all_deps.any?

        added
      end

      # Expand transitive dependencies (depth 2+).
      #
      # @param unit_id [String] Unit to expand from
      # @param seen_units [Set<String>] Already-seen unit identifiers
      # @param context_pool [Hash] Accumulator for unit data
      # @param dependency_map [Hash] Accumulator for dependency edges
      # @param remaining_depth [Integer] Remaining expansion depth
      def expand_transitive(unit_id, seen_units, context_pool, dependency_map, remaining_depth)
        return if remaining_depth <= 0

        graph = @reader.dependency_graph
        dep_ids = graph.dependencies_of(unit_id)
        resolved_deps = []

        dep_ids.each do |dep_id|
          dep_unit = @reader.find_unit(dep_id)
          next unless dep_unit

          resolved_deps << dep_id
          next if seen_units.include?(dep_id)

          seen_units.add(dep_id)
          context_pool[dep_id] = unit_summary(dep_unit)

          expand_transitive(dep_id, seen_units, context_pool, dependency_map, remaining_depth - 1)
        end

        dependency_map[unit_id] = resolved_deps if resolved_deps.any?
      end

      # Extract a summary hash from a full unit data hash.
      #
      # @param unit [Hash] Full unit data from IndexReader
      # @return [Hash] Summary with :type, :file_path, :source_code
      def unit_summary(unit)
        {
          type: unit['type'],
          file_path: unit['file_path'],
          source_code: unit['source_code']
        }
      end

      # Apply token budget by truncating source code from lowest-priority units.
      #
      # Priority order (highest first):
      # 1. Controller action chunks (directly hit by requests)
      # 2. Direct dependencies (models, services)
      # 3. Transitive dependencies
      #
      # @param context_pool [Hash] Unit data to budget
      # @param budget [Integer] Maximum tokens
      # @return [Integer] Actual token count
      def apply_budget(context_pool, budget)
        total = estimate_tokens(context_pool)
        return total if total <= budget

        # Truncate from the end (lowest priority = last added)
        identifiers = context_pool.keys.reverse
        identifiers.each do |id|
          break if total <= budget

          unit = context_pool[id]
          source = unit[:source_code]
          next unless source

          source_tokens = TokenUtils.estimate_tokens(source)
          unit[:source_code] = "# source truncated (#{source_tokens} tokens)"
          total -= source_tokens
          total += TokenUtils.estimate_tokens(unit[:source_code])
        end

        [total, 0].max
      end

      # Estimate total tokens for the context pool.
      #
      # @param context_pool [Hash] Unit data
      # @return [Integer] Estimated token count
      def estimate_tokens(context_pool)
        context_pool.values.sum do |unit|
          source = unit[:source_code] || ''
          TokenUtils.estimate_tokens(source) + 20 # overhead for tags/metadata
        end
      end

      # The budget target is the RENDERED document: the steps timeline, side
      # effects, dependency map, and markup all cost tokens the pool estimate
      # never counted, so a document could ship over budget while reporting a
      # compliant token_count. Measure to_context, tighten the source pool by
      # the observed overshoot, and re-measure; when nothing truncatable
      # remains, ship the floor flagged budget_exceeded instead of silently
      # over budget.
      def budgeted_document(parts, budget)
        rendered = rendered_tokens(parts)
        (RENDER_BUDGET_ATTEMPTS - 1).times do
          break if rendered <= budget
          break unless shrink_source_pool?(parts[:context_pool], budget, rendered)

          rendered = rendered_tokens(parts)
        end

        SessionFlowDocument.new(**parts, token_count: rendered, budget_exceeded: rendered > budget)
      end

      # to_context embeds the token count itself, so measure to a fixpoint:
      # the reported number must be the measure of the document printing it.
      def rendered_tokens(parts)
        count = 0
        3.times do
          probe = SessionFlowDocument.new(**parts, token_count: count)
          measured = TokenUtils.estimate_tokens(probe.to_context)
          return measured if measured == count

          count = measured
        end
        count
      end

      # Tighten the source-pool budget by the measured structural overshoot.
      # Returns false when no truncatable source remains — the floor.
      def shrink_source_pool?(context_pool, budget, rendered)
        return false unless context_pool.values.any? { |unit| truncatable_source?(unit) }

        overshoot = rendered - budget
        apply_budget(context_pool, [estimate_tokens(context_pool) - overshoot, 0].max)
        true
      end

      def truncatable_source?(unit)
        source = unit[:source_code]
        source && !source.start_with?('# source truncated')
      end

      # Build an empty document for sessions with no requests.
      #
      # @param session_id [String]
      # @return [SessionFlowDocument]
      def empty_document(session_id)
        SessionFlowDocument.new(session_id: session_id)
      end
    end
  end
end
