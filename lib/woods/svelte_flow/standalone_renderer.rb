# frozen_string_literal: true

require 'json'

module Woods
  module SvelteFlow
    # Renders a self-contained, single-file HTML visualization: the built app
    # JS/CSS and a scoped subgraph payload are inlined so the file opens over
    # file:// with no server and no network.
    #
    # The frontend reads the inlined `window.__WOODS_SUBGRAPH__` (graph + per-unit
    # sources) instead of calling the HTTP API.
    class StandaloneRenderer
      BUILD_DIR = File.expand_path('assets/build', __dir__)

      # @param build_dir [String] Directory holding the built app.js / app.css
      def initialize(build_dir: BUILD_DIR)
        @build_dir = build_dir
      end

      # Render the standalone HTML document.
      #
      # @param graph [Hash] Subgraph payload ({ 'nodes' =>, 'edges' =>, ... })
      # @param sources [Hash] identifier => { filePath, sourceCode, blobUrl }
      # @param title [String] Document title
      # @return [String] Complete HTML document
      def render(graph:, sources:, title:)
        # Force UTF-8 so hosts with an ASCII locale don't raise when the built
        # assets (which contain UTF-8) are interpolated into the template.
        app_js = File.read(File.join(@build_dir, 'app.js'), encoding: Encoding::UTF_8)
        app_css = File.read(File.join(@build_dir, 'app.css'), encoding: Encoding::UTF_8)
        data = script_safe(JSON.generate('graph' => graph, 'sources' => sources))

        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{escape_html(title)}</title>
            <style>#{app_css}</style>
          </head>
          <body>
            <div id="app"></div>
            <script>window.__WOODS_SUBGRAPH__ = #{data};</script>
            <script type="module">#{app_js}</script>
          </body>
          </html>
        HTML
      end

      private

      # Neutralize any `</script>` sequence inside inlined JSON so it can't close
      # the surrounding <script> tag. `<\/` is an equivalent escape in JS strings.
      #
      # @param json [String]
      # @return [String]
      def script_safe(json)
        json.gsub('</', '<\\/')
      end

      # @param str [String]
      # @return [String]
      def escape_html(str)
        str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
