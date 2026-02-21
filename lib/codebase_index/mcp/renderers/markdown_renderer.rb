# frozen_string_literal: true

module CodebaseIndex
  module MCP
    module Renderers
      # Renders MCP tool responses as pure Markdown.
      # Headers, tables, code blocks, and bullet lists — no JSON structural markers.
      class MarkdownRenderer < ToolResponseRenderer
        # ── lookup ──────────────────────────────────────────────────

        # @param data [Hash] Unit data from IndexReader#find_unit
        # @return [String] Markdown-formatted unit
        def render_lookup(data, **)
          return 'Unit not found' unless data.is_a?(Hash) && data['identifier']

          lines = []
          lines << "## #{data['identifier']} (#{data['type']})"
          lines << ''
          lines << "**File:** `#{data['file_path']}`" if data['file_path']
          lines << "**Namespace:** #{data['namespace']}" if data['namespace']
          lines << ''

          lines << render_metadata_section(data['metadata']) if data['metadata'].is_a?(Hash) && data['metadata'].any?

          if data['source_code']
            lines << '### Source'
            lines << ''
            lines << '```ruby'
            lines << data['source_code'].chomp
            lines << '```'
            lines << ''
          end

          if data['dependencies'].is_a?(Array) && data['dependencies'].any?
            lines << '### Dependencies'
            lines << ''
            data['dependencies'].each { |dep| lines << "- #{dep}" }
            lines << ''
          end

          if data['dependents'].is_a?(Array) && data['dependents'].any?
            lines << '### Dependents'
            lines << ''
            data['dependents'].each { |dep| lines << "- #{dep}" }
            lines << ''
          end

          lines.join("\n").rstrip
        end

        # ── search ──────────────────────────────────────────────────

        # @param data [Hash] Search results with :query, :result_count, :results
        # @return [String] Markdown search results
        def render_search(data, **)
          lines = []
          lines << "## Search: \"#{data[:query] || data['query']}\""
          count = data[:result_count] || data['result_count'] || 0
          lines << ''
          lines << "#{count} result#{'s' unless count == 1} found."
          lines << ''

          results = data[:results] || data['results'] || []
          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            match = r['match_field'] || r[:match_field]
            line = "- **#{ident}** (#{type})"
            line += " — matched in #{match}" if match
            lines << line
          end

          lines.join("\n").rstrip
        end

        # ── dependencies / dependents ───────────────────────────────

        # @param data [Hash] Traversal result with :root, :nodes, :found
        # @return [String] Markdown dependency tree
        def render_dependencies(data, **)
          render_traversal('Dependencies', data)
        end

        # @param data [Hash] Traversal result with :root, :nodes, :found
        # @return [String] Markdown dependents tree
        def render_dependents(data, **)
          render_traversal('Dependents', data)
        end

        # ── structure ───────────────────────────────────────────────

        # @param data [Hash] Structure data with :manifest and optional :summary
        # @return [String] Markdown structure overview
        def render_structure(data, **)
          manifest = data[:manifest] || data['manifest'] || {}
          lines = []
          lines << '## Codebase Structure'
          lines << ''

          %w[rails_version ruby_version git_branch git_sha extracted_at].each do |key|
            lines << "- **#{key.tr('_', ' ').capitalize}:** #{manifest[key]}" if manifest[key]
          end
          lines << "- **Total units:** #{manifest['total_units']}" if manifest['total_units']
          lines << ''

          counts = manifest['counts']
          if counts.is_a?(Hash) && counts.any?
            lines << '| Type | Count |'
            lines << '|------|-------|'
            counts.sort_by { |_k, v| -v }.each do |type, count|
              lines << "| #{type} | #{count} |"
            end
            lines << ''
          end

          summary = data[:summary] || data['summary']
          if summary
            lines << '### Summary'
            lines << ''
            lines << summary
          end

          lines.join("\n").rstrip
        end

        # ── graph_analysis ──────────────────────────────────────────

        # @param data [Hash] Graph analysis with section arrays and stats
        # @return [String] Markdown graph analysis
        def render_graph_analysis(data, **)
          lines = []
          lines << '## Graph Analysis'
          lines << ''

          stats = data['stats'] || data[:stats]
          if stats.is_a?(Hash)
            stats.each { |k, v| lines << "- **#{k}:** #{v}" }
            lines << ''
          end

          %w[orphans dead_ends hubs cycles bridges].each do |section|
            items = data[section] || data[section.to_sym]
            next unless items.is_a?(Array) && items.any?

            lines << "### #{section.tr('_', ' ').capitalize}"
            lines << ''
            items.each do |item|
              lines << if item.is_a?(Hash)
                         "- **#{item['identifier']}** (#{item['type']}) — #{item['dependent_count']} dependents"
                       else
                         "- #{item}"
                       end
            end

            total_key = "#{section}_total"
            if data[total_key]
              lines << ''
              lines << "_Showing #{items.size} of #{data[total_key]} (truncated)_"
            end
            lines << ''
          end

          lines.join("\n").rstrip
        end

        # ── pagerank ────────────────────────────────────────────────

        # @param data [Hash] PageRank data with :total_nodes and :results
        # @return [String] Markdown table of ranked nodes
        def render_pagerank(data, **)
          lines = []
          lines << '## PageRank Scores'
          lines << ''
          lines << "#{data[:total_nodes] || data['total_nodes']} nodes in graph."
          lines << ''
          lines << '| Rank | Identifier | Type | Score |'
          lines << '|------|-----------|------|-------|'

          results = data[:results] || data['results'] || []
          results.each_with_index do |r, i|
            ident = r[:identifier] || r['identifier']
            type = r[:type] || r['type']
            score = r[:score] || r['score']
            lines << "| #{i + 1} | #{ident} | #{type} | #{score} |"
          end

          lines.join("\n").rstrip
        end

        # ── framework ───────────────────────────────────────────────

        # @param data [Hash] Framework search results
        # @return [String] Markdown framework results
        def render_framework(data, **)
          lines = []
          keyword = data[:keyword] || data['keyword']
          count = data[:result_count] || data['result_count'] || 0
          lines << "## Framework: \"#{keyword}\""
          lines << ''
          lines << "#{count} result#{'s' unless count == 1} found."
          lines << ''

          results = data[:results] || data['results'] || []
          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            file = r['file_path'] || r[:file_path]
            line = "- **#{ident}** (#{type})"
            line += " — `#{file}`" if file
            lines << line
          end

          lines.join("\n").rstrip
        end

        # ── recent_changes ──────────────────────────────────────────

        # @param data [Hash] Recent changes with :result_count and :results
        # @return [String] Markdown table of recent changes
        def render_recent_changes(data, **)
          lines = []
          count = data[:result_count] || data['result_count'] || 0
          lines << '## Recent Changes'
          lines << ''
          lines << "#{count} recently modified unit#{'s' unless count == 1}."
          lines << ''
          lines << '| Identifier | Type | Last Modified | Author |'
          lines << '|-----------|------|---------------|--------|'

          results = data[:results] || data['results'] || []
          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            modified = r['last_modified'] || r[:last_modified] || '-'
            author = r['author'] || r[:author] || '-'
            lines << "| #{ident} | #{type} | #{modified} | #{author} |"
          end

          lines.join("\n").rstrip
        end

        # ── Default fallback ────────────────────────────────────────

        # @param data [Object] Any data
        # @return [String] Markdown-formatted default output
        def render_default(data)
          case data
          when Hash
            render_hash_as_markdown(data)
          when Array
            render_array_as_markdown(data)
          else
            data.to_s
          end
        end

        private

        def render_traversal(label, data)
          root = data[:root] || data['root']
          found = data[:found] || data['found']
          nodes = data[:nodes] || data['nodes'] || {}
          message = data[:message] || data['message']

          lines = []
          lines << "## #{label} of #{root}"
          lines << ''

          if found == false
            (lines << message) || "Identifier '#{root}' not found in the index."
            return lines.join("\n").rstrip
          end

          nodes.each do |id, info|
            depth = info['depth'] || info[:depth] || 0
            deps = info['deps'] || info[:deps] || []
            indent = '  ' * depth
            lines << "#{indent}- **#{id}**"
            deps.each { |d| lines << "#{indent}  - #{d}" }
          end

          lines.join("\n").rstrip
        end

        def render_metadata_section(metadata)
          lines = []
          lines << '### Metadata'
          lines << ''

          metadata.each do |key, value|
            case value
            when Array
              next if value.empty?

              lines << "**#{key}:**"
              value.each do |item|
                if item.is_a?(Hash)
                  summary = item.map { |k, v| "#{k}: #{v}" }.join(', ')
                  lines << "  - #{summary}"
                else
                  lines << "  - #{item}"
                end
              end
            when Hash
              lines << "**#{key}:** #{value.map { |k, v| "#{k}=#{v}" }.join(', ')}"
            else
              lines << "**#{key}:** #{value}"
            end
          end
          lines << ''
          lines.join("\n")
        end

        def render_hash_as_markdown(hash)
          lines = []
          hash.each do |key, value|
            case value
            when Hash
              lines << "**#{key}:**"
              value.each { |k, v| lines << "  - #{k}: #{v}" }
            when Array
              lines << "**#{key}:** #{value.size} items"
              value.first(10).each do |item|
                lines << "  - #{item.is_a?(Hash) ? item.values.first(3).join(', ') : item}"
              end
            else
              lines << "**#{key}:** #{value}"
            end
          end
          lines.join("\n")
        end

        def render_array_as_markdown(array)
          return '_(empty)_' if array.empty?

          if array.first.is_a?(Hash)
            keys = array.first.keys.first(5)
            lines = []
            lines << "| #{keys.join(' | ')} |"
            lines << "| #{keys.map { '---' }.join(' | ')} |"
            array.each do |row|
              lines << "| #{keys.map { |k| row[k] }.join(' | ')} |"
            end
            lines.join("\n")
          else
            array.map { |item| "- #{item}" }.join("\n")
          end
        end
      end
    end
  end
end
