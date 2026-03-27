# frozen_string_literal: true

module Woods
  module Unblocked
    # Converts extracted unit JSON into condensed Markdown documents
    # optimized for Unblocked's code review and Q&A context.
    #
    # Each unit type has a specialized formatting strategy that emphasizes
    # what matters for code review: associations, blast radius, entry points,
    # side effects, and structural complexity.
    #
    # @example
    #   builder = DocumentBuilder.new(repo_url: "https://github.com/bigcartel/admin")
    #   doc = builder.build(unit_data)
    #   # => { title: "Order (model)", body: "# Order (model)\n...", uri: "https://..." }
    #
    class DocumentBuilder
      # @param repo_url [String] GitHub repo base URL for citation URIs
      def initialize(repo_url:)
        @repo_url = repo_url.chomp('/')
      end

      # Build a document hash from a unit's extracted data.
      #
      # @param unit_data [Hash] Parsed unit JSON (from IndexReader)
      # @return [Hash] { title:, body:, uri: }
      def build(unit_data)
        type = unit_data['type']
        identifier = unit_data['identifier']
        file_path = unit_data['file_path']

        {
          title: "#{identifier} (#{type})",
          body: build_body(unit_data),
          uri: build_uri(file_path)
        }
      end

      private

      def build_uri(file_path)
        return @repo_url unless file_path

        "#{@repo_url}/blob/main/#{file_path}"
      end

      def build_body(unit_data)
        type = unit_data['type']
        case type
        when 'model' then build_model_body(unit_data)
        when 'controller' then build_controller_body(unit_data)
        when 'service', 'job', 'mailer', 'manager', 'decorator', 'concern'
          build_generic_body(unit_data)
        when 'graphql', 'graphql_type', 'graphql_mutation', 'graphql_resolver', 'graphql_query'
          build_graphql_body(unit_data)
        else build_generic_body(unit_data)
        end
      end

      # ── Model formatting ─────────────────────────────────────────────

      def build_model_body(unit)
        meta = unit['metadata'] || {}
        sections = []

        sections << model_header(unit, meta)
        sections << model_associations(meta)
        sections << model_dependents(unit)
        sections << model_entry_points(unit)
        sections << model_schema_highlights(meta)
        sections << model_side_effects(unit)

        sections.compact.join("\n\n")
      end

      def model_header(unit, meta)
        parts = ["# #{unit['identifier']} (model)"]
        file_info = ["**File:** `#{unit['file_path']}`"]
        file_info << "**LOC:** #{meta['loc']}" if meta['loc']
        file_info << "**Table:** #{meta['table_name']}" if meta['table_name']
        column_count = meta['column_count'] || (meta['columns'] || []).size
        file_info << "(#{column_count} columns)" if column_count&.positive?
        parts << file_info.join(' | ')
        parts.join("\n")
      end

      def model_associations(meta)
        assocs = meta['associations'] || []
        return nil if assocs.empty?

        grouped = assocs.group_by { |a| a['type'] }
        lines = ["## Associations (#{assocs.size})"]

        %w[belongs_to has_many has_one has_and_belongs_to_many].each do |type|
          items = grouped[type]
          next unless items&.any?

          targets = items.map do |a|
            name = a['target'] || a['name']
            dep = a.dig('options', 'dependent')
            dep ? "#{name} (#{dep})" : name
          end
          lines << "**#{type}:** #{targets.join(', ')}"
        end

        lines.join("\n")
      end

      def model_dependents(unit)
        deps = unit['dependents'] || []
        return nil if deps.empty?

        grouped = deps.group_by { |d| d['type'] }
        summary_parts = grouped.map { |type, items| "#{items.size} #{type}s" }

        lines = ["## Dependents (#{deps.size} units)"]
        lines << summary_parts.join(', ')

        # Blast radius assessment
        if deps.size > 50
          lines << '**High blast radius** — changes here affect many parts of the codebase'
        elsif deps.size > 20
          lines << '**Moderate blast radius** — changes may ripple to dependent code'
        end

        lines.join("\n")
      end

      def model_entry_points(unit)
        deps = unit['dependents'] || []
        controllers = deps.select { |d| d['type'] == 'controller' }
        graphql = deps.select { |d| d['type']&.start_with?('graphql') }
        jobs = deps.select { |d| d['type'] == 'job' }

        return nil if controllers.empty? && graphql.empty?

        lines = ['## Entry Points']
        lines << "**Controllers:** #{controllers.map { |c| c['identifier'] }.join(', ')}" if controllers.any?
        lines << "**GraphQL:** #{graphql.map { |g| g['identifier'] }.join(', ')}" if graphql.any?
        lines << "**Jobs:** #{jobs.map { |j| j['identifier'] }.join(', ')}" if jobs.any?

        lines.join("\n")
      end

      def model_schema_highlights(meta)
        parts = []

        enums = meta['enums']
        if enums.is_a?(Hash) && enums.any?
          enum_strs = enums.map { |name, values| "#{name} (#{format_enum_values(values)})" }
          parts << "**Enums:** #{enum_strs.join('; ')}"
        end

        scopes = meta['scopes']
        parts << "**Scopes:** #{scopes.map { |s| s['name'] }.join(', ')}" if scopes.is_a?(Array) && scopes.any?

        concerns = meta['inlined_concerns']
        parts << "**Concerns:** #{concerns.join(', ')}" if concerns.is_a?(Array) && concerns.any?

        callbacks = meta['callbacks']
        if callbacks.is_a?(Array) && callbacks.any?
          parts << "**Callbacks (#{callbacks.size}):** #{format_callbacks(callbacks)}"
        end

        return nil if parts.empty?

        (['## Schema Highlights'] + parts).join("\n")
      end

      def model_side_effects(unit)
        deps = unit['dependents'] || []
        jobs = deps.select { |d| d['type'] == 'job' }
        mailers = deps.select { |d| d['type'] == 'mailer' }

        return nil if jobs.empty? && mailers.empty?

        lines = ['## Side Effects']
        lines << "**Jobs:** #{jobs.map { |j| j['identifier'] }.join(', ')}" if jobs.any?
        lines << "**Mailers:** #{mailers.map { |m| m['identifier'] }.join(', ')}" if mailers.any?

        lines.join("\n")
      end

      # ── Controller formatting ────────────────────────────────────────

      def build_controller_body(unit)
        meta = unit['metadata'] || {}
        sections = []

        sections << "# #{unit['identifier']} (controller)"
        sections << "**File:** `#{unit['file_path']}`"

        ancestors = meta['ancestors']
        sections << "**Inherits:** #{ancestors[1..3]&.join(' → ')}" if ancestors.is_a?(Array) && ancestors.size > 1

        sections << controller_routes(meta)
        sections << controller_dependencies(unit)
        sections << controller_dependents(unit)

        sections.compact.join("\n\n")
      end

      def controller_routes(meta)
        routes = meta['routes']
        return nil unless routes.is_a?(Hash) && routes.any?

        lines = ['## Routes']
        routes.each do |action, route_list|
          next unless route_list.is_a?(Array)

          route_list.each do |route|
            next unless route.is_a?(Hash)

            lines << "- `#{route['verb']} #{route['path']}` (#{action})"
          end
        end

        lines.size > 1 ? lines.first(20).join("\n") : nil
      end

      def controller_dependencies(unit)
        deps = unit['dependencies'] || []
        return nil if deps.empty?

        models = deps.select { |d| d['type'] == 'model' }.map { |d| d['target'] }
        return nil if models.empty?

        "## Dependencies\n**Models:** #{models.join(', ')}"
      end

      def controller_dependents(unit)
        deps = unit['dependents'] || []
        views = deps.select { |d| d['type'] == 'view_template' }
        return nil if views.empty?

        "## Views\n#{views.map { |v| "- `#{v['identifier']}`" }.first(10).join("\n")}"
      end

      # ── GraphQL formatting ───────────────────────────────────────────

      def build_graphql_body(unit)
        sections = []

        sections << "# #{unit['identifier']} (#{unit['type']})"
        sections << "**File:** `#{unit['file_path']}`"

        deps = unit['dependencies'] || []
        models = deps.select { |d| d['type'] == 'model' }.map { |d| d['target'] }
        sections << "**Models:** #{models.join(', ')}" if models.any?

        dependents = unit['dependents'] || []
        sections << "**Referenced by:** #{dependents.size} units" if dependents.any?

        sections.compact.join("\n\n")
      end

      # ── Generic formatting (services, jobs, mailers, etc.) ──────────

      def build_generic_body(unit)
        meta = unit['metadata'] || {}
        sections = []

        sections << "# #{unit['identifier']} (#{unit['type']})"
        sections << "**File:** `#{unit['file_path']}`"
        sections << "**LOC:** #{meta['loc']}" if meta['loc']

        deps = unit['dependencies'] || []
        if deps.any?
          by_type = deps.group_by { |d| d['type'] }
          dep_parts = by_type.map { |type, items| "#{type}: #{items.map { |d| d['target'] }.join(', ')}" }
          sections << "## Dependencies\n#{dep_parts.join("\n")}"
        end

        dependents = unit['dependents'] || []
        if dependents.any?
          grouped = dependents.group_by { |d| d['type'] }
          summary = grouped.map { |type, items| "#{items.size} #{type}s" }
          sections << "## Dependents (#{dependents.size})\n#{summary.join(', ')}"
        end

        sections.compact.join("\n\n")
      end

      # ── Helpers ──────────────────────────────────────────────────────

      def format_enum_values(values)
        case values
        when Hash then values.keys.first(5).join(', ')
        when Array then values.first(5).join(', ')
        else values.to_s
        end
      end

      def format_callbacks(callbacks)
        callbacks.first(5).map do |cb|
          "#{cb['type']}: #{cb['filter']}"
        end.join(', ')
      end
    end
  end
end
