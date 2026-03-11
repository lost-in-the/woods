# frozen_string_literal: true

module CodebaseIndex
  module MCP
    module Renderers
      # Renders MCP tool responses as Markdown wrapped in XML boundary tags.
      # Matches Anthropic's recommended format: XML tags for section boundaries,
      # Markdown for content.
      class ClaudeRenderer < MarkdownRenderer
        # @param data [Hash] Unit data
        # @return [String] XML-wrapped Markdown
        def render_lookup(data, **)
          return 'Unit not found' unless data.is_a?(Hash) && data['identifier']

          content = super
          wrap_xml('lookup_result', content,
                   identifier: data['identifier'], type: data['type'])
        end

        # @param data [Hash] Search results
        # @return [String] XML-wrapped Markdown
        def render_search(data, **)
          content = super
          query = data[:query] || data['query']
          wrap_xml('search_results', content, query: query)
        end

        def render_dependencies(data, **)
          content = super
          root = data[:root] || data['root']
          wrap_xml('dependencies', content, root: root)
        end

        def render_dependents(data, **)
          content = super
          root = data[:root] || data['root']
          wrap_xml('dependents', content, root: root)
        end

        def render_structure(data, **)
          wrap_xml('structure', super)
        end

        def render_graph_analysis(data, **)
          wrap_xml('graph_analysis', super)
        end

        def render_pagerank(data, **)
          wrap_xml('pagerank', super)
        end

        def render_framework(data, **)
          content = super
          keyword = data[:keyword] || data['keyword']
          wrap_xml('framework_results', content, keyword: keyword)
        end

        def render_recent_changes(data, **)
          wrap_xml('recent_changes', super)
        end

        def render_default(data)
          wrap_xml('result', super)
        end

        private

        # Wrap content in an XML tag with optional attributes.
        #
        # @param tag [String] XML tag name
        # @param content [String] Inner content
        # @param attrs [Hash] XML attributes
        # @return [String] XML-wrapped content
        def wrap_xml(tag, content, **attrs)
          attr_str = attrs.map { |k, v| " #{k}=\"#{v}\"" }.join
          "<#{tag}#{attr_str}>\n#{content}\n</#{tag}>"
        end
      end
    end
  end
end
