# frozen_string_literal: true

require_relative 'dependent_families'
require_relative 'path_tool'
require_relative 'routes_without_action'
require_relative 'traversal_evidence_index'
require_relative 'traversal_evidence_text'

module Woods
  module MCP
    # Base class for rendering MCP tool responses in different output formats.
    #
    # Subclasses implement tool-specific render methods (render_lookup, render_search, etc.)
    # and a render_default fallback. The dispatch uses convention: tool name maps to method name.
    #
    # @example
    #   renderer = ToolResponseRenderer.for(:markdown)
    #   renderer.render(:lookup, unit_data)
    #
    class ToolResponseRenderer
      VALID_FORMATS = %i[claude markdown plain json].freeze

      # Sections of graph_analysis.json in display order. Shared by the
      # graph_analysis tool (enum and pagination) and the text renderers.
      GRAPH_ANALYSIS_SECTIONS = %w[
        orphans dead_ends hubs cycles bridges
        cross_database_edges volatile_dependencies undeclared_package_edges
        unresolvable_routes
      ].freeze

      # Factory method to build the appropriate renderer for a format.
      #
      # @param format [Symbol] One of :claude, :markdown, :plain, :json
      # @return [ToolResponseRenderer] A renderer instance
      # @raise [ArgumentError] if format is unknown
      def self.for(format)
        require_relative 'renderers/markdown_renderer'
        require_relative 'renderers/claude_renderer'
        require_relative 'renderers/plain_renderer'
        require_relative 'renderers/json_renderer'

        case format
        when :claude   then Renderers::ClaudeRenderer.new
        when :markdown then Renderers::MarkdownRenderer.new
        when :plain    then Renderers::PlainRenderer.new
        when :json     then Renderers::JsonRenderer.new
        else raise ArgumentError, "Unknown format: #{format.inspect}. Valid: #{VALID_FORMATS.inspect}"
        end
      end

      # Render a tool response. Dispatches to render_<tool_name> if defined,
      # otherwise falls back to render_default.
      #
      # @param tool_name [Symbol, String] The tool name
      # @param data [Object] The tool result data
      # @param opts [Hash] Additional rendering options
      # @return [String] Rendered response text
      def render(tool_name, data, **opts)
        method_name = :"render_#{tool_name}"
        if respond_to?(method_name, true)
          send(method_name, data, **opts)
        else
          render_default(data)
        end
      end

      # Default rendering — subclasses must implement.
      #
      # @param data [Object] The data to render
      # @return [String] Rendered text
      def render_default(data)
        raise NotImplementedError, "#{self.class}#render_default must be implemented"
      end

      private

      # Where a member answer's method is: the file a reader opens and its
      # lines, then the lines in the published source that holds it, the
      # definitions it overrides and what the index could not establish.
      # An answer the index cannot rank lists each candidate's place instead.
      # Shared by the text renderers' `render_lookup_member`.
      #
      # @param data [Hash] a {LookupMember.answer}
      # @return [Array<String>]
      def member_location_lines(data)
        lines = data['member'] ? definition_location_lines(data, data) : []
        Array(data['other_definitions']).each do |other|
          from = other['file_unit'] ? " (from #{other['file_unit']})" : ''
          lines << "Also defined at #{published_source_name(other, data)} " \
                   "#{member_lines(other['line'], other['end_line'])}#{from}; the definition above overrides it."
        end
        Array(data['caveats']).each { |caveat| lines << "Caveat: #{caveat}" }
        lines
      end

      # The file and lines of one definition: the answer's own, or one of its
      # `candidates`.
      #
      # @param definition [Hash] holds `member` and optionally `defined_in`
      #   and `inherited_from`
      # @param data [Hash] the whole answer
      # @return [Array<String>]
      def definition_location_lines(definition, data)
        member = definition['member'] || {}
        owner = data['member_of'] || {}
        concern = definition['defined_in']
        ancestor = definition['inherited_from']
        file = (concern || ancestor || owner)['file_path']
        where = file ? "File: #{file}" : 'File: unknown'
        if concern
          role = concern['prepended'] ? 'prepended' : 'inlined'
          where += " (#{concern['identifier']}, #{role} into #{concern['included_by'] || owner['identifier']})"
        elsif ancestor
          where += " (#{ancestor['identifier']}, inherited by #{owner['identifier']})"
        end
        first = member['file_line']
        where += first.is_a?(Integer) ? ", #{member_lines(first, member['file_end_line'])}" : ', lines not mapped'
        [where, "#{published_source_name(member, data)}: #{member_lines(member['line'], member['end_line'])}"]
      end

      # @return [String] "Published source of X", the unit whose published
      #   source an entry's `line` counts in
      def published_source_name(entry, data)
        "Published source of #{entry['unit'] || data.dig('member_of', 'identifier')}"
      end

      def member_lines(first, last)
        last.is_a?(Integer) && last != first ? "lines #{first}-#{last}" : "line #{first}"
      end

      # A value as tool text prints it: a Hash as `(key: value, ...)` and an
      # Array as `[a, b]`, nested alike, so no Ruby `inspect` form (`{"k" =>
      # "v"}`, `["a", "b"]`) ever reaches an agent, who would read it as data.
      # Inside them nil prints as `null`; any other value prints as itself.
      #
      # @param value [Object]
      # @return [String]
      def inline_value(value)
        case value
        when Hash then value.empty? ? '{}' : "(#{value.map { |k, v| "#{k}: #{nested_value(v)}" }.join(', ')})"
        when Array then "[#{value.map { |item| nested_value(item) }.join(', ')}]"
        else value.to_s
        end
      end

      def nested_value(value)
        value.nil? ? 'null' : inline_value(value)
      end

      # The name printed for one entry of a metadata Hash: a controller's
      # routed action that nothing answers is marked in its `routes`.
      #
      # @param metadata [Hash] the unit's metadata
      # @param key [String] the metadata key being rendered
      # @param name [String] the entry's own key
      # @return [String]
      def entry_label(metadata, key, name)
        RoutesWithoutAction.route_label(metadata, key, name)
      end

      # The dispatch target and verdict of an `unresolvable_routes` entry.
      #
      # @param item [Hash] `{ 'route', 'controller', 'action', 'reason' }`
      # @return [String] e.g. `PostsController#destroy (missing_action)`
      def route_target(item)
        "#{item['controller']}##{item['action']} (#{item['reason']})"
      end

      def traversal_coverage_lines(data)
        coverage = fetch_key(data, :graph_coverage)
        notice = fetch_key(coverage, :notice) if coverage.is_a?(Hash)
        notice ? [notice] : []
      end

      # The `dependents` headline and family counts, formatted from the
      # server's `dependent_counts` without recounting the page.
      #
      # @return [Array<String>] empty when the result carries no counts
      def dependent_counts_lines(data)
        counts = fetch_key(data, :dependent_counts)
        return [] unless counts.is_a?(Hash)

        exact = fetch_key(counts, :exact) != false
        bound = exact ? '' : 'at least '
        families = fetch_key(counts, :families, {})
        mapped = fetch_key(counts, :mapped_tests, 0)
        included = fetch_key(counts, :reverse_includes_tests) == true
        headline = "Recorded dependents: #{bound}#{fetch_key(counts, :headline)} " \
                   "(#{included ? 'code and Mapped tests' : 'code'}); Mapped tests: #{bound}#{mapped}" \
                   "#{included ? ' (counted in the headline)' : ' (listed, not counted)'}."
        by_family = DependentFamilies::FAMILIES.map { |family| "#{family} #{fetch_key(families, family, 0)}" }
        scope = exact ? 'over the whole traversal' : 'over the whole traversal (lower bounds: the walk stopped early)'
        detail = "By family: #{by_family.join(', ')}; total #{bound}#{fetch_key(counts, :total)} #{scope}."
        [headline, detail, *category_line(counts, bound), *selection_lines(data, bound)]
      end

      # @return [String] a row's label suffix, e.g. ` (Mapped test)`
      def mapped_test_suffix(info)
        suffix = fetch_key(info, :mapped_test) ? ' (Mapped test)' : ''
        suffix += ' (reached through rows outside the selection)' if fetch_key(info, :reached_through_hidden)
        hidden = fetch_key(info, :hidden_deps).to_i
        suffix += " (#{hidden} dependent#{'s' unless hidden == 1} outside the selection)" if hidden.positive?
        suffix
      end

      # Nonzero categories only: every row has one, and a list of zeros hides the ones that matter.
      def category_line(counts, bound)
        categories = fetch_key(counts, :categories)
        return [] unless categories.is_a?(Hash)

        named = DependentFamilies::CATEGORIES.filter_map do |category|
          count = fetch_key(categories, category, 0)
          "#{category} #{bound}#{count}" if count.positive?
        end
        named.empty? ? [] : ["By category: #{named.join(', ')}."]
      end

      def selection_lines(data, bound)
        selection = fetch_key(data, :selection)
        return [] unless selection.is_a?(Hash)

        counts = fetch_key(selection, :counts, {})
        included = fetch_key(counts, :reverse_includes_tests) == true
        requested = Array(fetch_key(selection, :requested)).join(', ')
        listed = "Selected (families: #{requested}): #{bound}#{fetch_key(counts, :total)} listed, " \
                 "#{bound}#{fetch_key(counts, :not_selected)} traversed but not listed; " \
                 "headline #{bound}#{fetch_key(counts, :headline)} (#{included ? 'code and Mapped tests' : 'code'}), " \
                 "Mapped tests #{bound}#{fetch_key(counts, :mapped_tests)}."
        [listed, *category_line(counts, bound).map { |line| line.sub('By category:', 'Selected by category:') },
         'The walk was not pruned; deps list only edges between listed rows.']
      end

      def traversal_lower_bound_note(data, shown)
        return unless fetch_key(data, :total_is_exact) == false

        total = fetch_key(data, :nodes_total, shown)
        offset = fetch_key(data, :nodes_offset, 0)
        position = offset.positive? ? " from offset #{offset}" : ''
        "Showing #{shown} of at least #{total}#{position} " \
          "(total unknown: #{fetch_key(data, :partial_reason)})."
      end

      def domain_page_line(data, shown, total)
        offset = fetch_key(data, :offset, 0)
        position = offset.positive? ? " from offset #{offset}" : ''
        "Showing #{shown} of #{total} domains#{position}."
      end

      def search_completeness_lines(data)
        evidence = fetch_key(data, :completeness)
        return [] unless evidence.is_a?(Hash)

        more = { true => 'yes', false => 'no', nil => 'unknown' }.fetch(fetch_key(evidence, :has_more))
        total = fetch_key(evidence, :total_matches)
        lines = [
          "Search completeness: #{fetch_key(evidence, :status)} (#{fetch_key(evidence, :reason)}).",
          "More matches: #{more}; total matches: #{total.nil? ? 'unknown' : total}; " \
          "matched lower bound: #{fetch_key(evidence, :matched_lower_bound)}."
        ]
        scope = fetch_key(data, :applied_scope)
        if scope
          lines << "Applied scope: packages=#{nested_value(fetch_key(scope, :packages))}; " \
                   "source_paths=#{nested_value(fetch_key(scope, :source_paths))}; " \
                   "eligible units=#{fetch_key(scope, :eligible_units)}."
        end
        hint = fetch_key(data, :hint)
        lines << hint if hint
        lines
      end

      # Fetch a value from a hash by symbol or string key, falling back to a default.
      #
      # Handles data hashes that may use either symbol or string keys (e.g., data
      # assembled from JSON parsing vs. direct Hash literals).
      #
      # @param data [Hash] The source hash
      # @param key [Symbol, String] The key to look up
      # @param default [Object] Value to return when key is absent (default: nil)
      # @return [Object]
      def fetch_key(data, key, default = nil)
        sym_key = key.to_sym
        str_key = key.to_s
        if data.key?(sym_key)
          data[sym_key]
        elsif data.key?(str_key)
          data[str_key]
        else
          default
        end
      end
    end
  end
end
