# frozen_string_literal: true

module CodebaseIndex
  module MCP
    module Renderers
      # Renders MCP tool responses as plain text with === dividers.
      # Lightweight fallback format with no markup.
      class PlainRenderer < ToolResponseRenderer
        DIVIDER = ('=' * 60).freeze

        def render_lookup(data, **)
          return 'Unit not found' unless data.is_a?(Hash) && data['identifier']

          lines = []
          lines << "#{data['identifier']} (#{data['type']})"
          lines << DIVIDER
          lines << "File: #{data['file_path']}" if data['file_path']
          lines << "Namespace: #{data['namespace']}" if data['namespace']
          lines << ''

          if data['metadata'].is_a?(Hash) && data['metadata'].any?
            lines << 'Metadata:'
            data['metadata'].each do |key, value|
              case value
              when Array
                next if value.empty?

                lines << "  #{key}:"
                value.each do |item|
                  lines << "    - #{item.is_a?(Hash) ? item.map { |k, v| "#{k}: #{v}" }.join(', ') : item}"
                end
              when Hash
                lines << "  #{key}: #{value.map { |k, v| "#{k}=#{v}" }.join(', ')}"
              else
                lines << "  #{key}: #{value}"
              end
            end
            lines << ''
          end

          if data['source_code']
            lines << 'Source:'
            lines << DIVIDER
            lines << data['source_code'].chomp
            lines << DIVIDER
            lines << ''
          end

          if data['dependencies'].is_a?(Array) && data['dependencies'].any?
            lines << "Dependencies: #{data['dependencies'].join(', ')}"
          end

          if data['dependents'].is_a?(Array) && data['dependents'].any?
            lines << "Dependents: #{data['dependents'].join(', ')}"
          end

          lines.join("\n").rstrip
        end

        def render_search(data, **)
          query = data[:query] || data['query']
          count = data[:result_count] || data['result_count'] || 0
          results = data[:results] || data['results'] || []

          lines = []
          lines << "Search: \"#{query}\" (#{count} results)"
          lines << DIVIDER

          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            lines << "  #{ident} (#{type})"
          end

          lines.join("\n").rstrip
        end

        def render_dependencies(data, **)
          render_plain_traversal('Dependencies', data)
        end

        def render_dependents(data, **)
          render_plain_traversal('Dependents', data)
        end

        def render_structure(data, **)
          manifest = data[:manifest] || data['manifest'] || {}
          lines = []
          lines << 'Codebase Structure'
          lines << DIVIDER

          %w[rails_version ruby_version git_branch git_sha extracted_at total_units].each do |key|
            lines << "  #{key}: #{manifest[key]}" if manifest[key]
          end

          counts = manifest['counts']
          if counts.is_a?(Hash) && counts.any?
            lines << ''
            lines << 'Unit counts:'
            counts.sort_by { |_k, v| -v }.each { |type, count| lines << "  #{type}: #{count}" }
          end

          summary = data[:summary] || data['summary']
          if summary
            lines << ''
            lines << DIVIDER
            lines << summary
          end

          lines.join("\n").rstrip
        end

        def render_graph_analysis(data, **)
          lines = []
          lines << 'Graph Analysis'
          lines << DIVIDER

          stats = data['stats'] || data[:stats]
          if stats.is_a?(Hash)
            stats.each { |k, v| lines << "  #{k}: #{v}" }
            lines << ''
          end

          %w[orphans dead_ends hubs cycles bridges].each do |section|
            items = data[section] || data[section.to_sym]
            next unless items.is_a?(Array) && items.any?

            lines << "#{section.tr('_', ' ').upcase}:"
            items.each do |item|
              lines << if item.is_a?(Hash)
                         "  #{item['identifier']} (#{item['type']}) - #{item['dependent_count']} dependents"
                       else
                         "  #{item}"
                       end
            end

            total_key = "#{section}_total"
            lines << "  (showing #{items.size} of #{data[total_key]})" if data[total_key]
            lines << ''
          end

          lines.join("\n").rstrip
        end

        def render_pagerank(data, **)
          lines = []
          lines << "PageRank Scores (#{data[:total_nodes] || data['total_nodes']} nodes)"
          lines << DIVIDER

          results = data[:results] || data['results'] || []
          results.each_with_index do |r, i|
            ident = r[:identifier] || r['identifier']
            type = r[:type] || r['type']
            score = r[:score] || r['score']
            lines << "  #{i + 1}. #{ident} (#{type}) - #{score}"
          end

          lines.join("\n").rstrip
        end

        def render_framework(data, **)
          keyword = data[:keyword] || data['keyword']
          count = data[:result_count] || data['result_count'] || 0
          results = data[:results] || data['results'] || []

          lines = []
          lines << "Framework: \"#{keyword}\" (#{count} results)"
          lines << DIVIDER

          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            lines << "  #{ident} (#{type})"
          end

          lines.join("\n").rstrip
        end

        def render_recent_changes(data, **)
          count = data[:result_count] || data['result_count'] || 0
          results = data[:results] || data['results'] || []

          lines = []
          lines << "Recent Changes (#{count} units)"
          lines << DIVIDER

          results.each do |r|
            ident = r['identifier'] || r[:identifier]
            type = r['type'] || r[:type]
            modified = r['last_modified'] || r[:last_modified] || '-'
            lines << "  #{ident} (#{type}) - #{modified}"
          end

          lines.join("\n").rstrip
        end

        # @param data [Object] Any data
        # @return [String] Plain text output
        def render_default(data)
          case data
          when Hash
            data.map { |k, v| "#{k}: #{v}" }.join("\n")
          when Array
            data.map { |item| "  #{item}" }.join("\n")
          else
            data.to_s
          end
        end

        private

        def render_plain_traversal(label, data)
          root = data[:root] || data['root']
          found = data[:found] || data['found']
          nodes = data[:nodes] || data['nodes'] || {}
          message = data[:message] || data['message']

          lines = []
          lines << "#{label} of #{root}"
          lines << DIVIDER

          if found == false
            lines << (message || "Identifier '#{root}' not found in the index.")
            return lines.join("\n").rstrip
          end

          nodes.each do |id, info|
            depth = info['depth'] || info[:depth] || 0
            deps = info['deps'] || info[:deps] || []
            indent = '  ' * (depth + 1)
            lines << "#{indent}#{id}"
            deps.each { |d| lines << "#{indent}  -> #{d}" }
          end

          lines.join("\n").rstrip
        end
      end
    end
  end
end
