# frozen_string_literal: true

require 'json'
require 'woods/atomic_file'
require 'woods/explorer/errors'
require 'woods/explorer/data_builder'

module Woods
  module Explorer
    # Renders an extraction index as a self-contained, dependency-free HTML
    # explorer plus a machine-readable data.json sidecar. The generated
    # index.html embeds all CSS/JS/data inline, so it works from file://, an
    # artifact host, or any static server — no network access required.
    #
    # Output layout (inside output_dir, default <index_dir>/explorer):
    #   index.html       the explorer app (open in any browser)
    #   data.json        the same payload, pretty-printed, for AI agents/tools
    #   README.md        what these files are and how to serve them
    #   .woods-explorer  ownership sentinel (safe-overwrite guard)
    #
    # Re-running against an unchanged extraction produces byte-identical
    # output — no timestamps are stamped at build time.
    class SiteBuilder
      # Ownership sentinel: the builder refuses to overwrite a non-empty
      # directory it didn't create unless force: is set.
      SENTINEL = '.woods-explorer'

      ASSETS_DIR = File.expand_path('assets', __dir__)

      # @param index_dir [String] extraction output directory (has manifest.json)
      # @param output_dir [String, nil] destination (default: index_dir/explorer)
      # @param reader [Woods::MCP::IndexReader, nil] injectable for tests
      # @param include_framework [Boolean] include rails_source nodes
      # @param force [Boolean] overwrite a foreign non-empty output directory
      # @param output [IO, nil] progress stream
      def initialize(index_dir:, output_dir: nil, reader: nil, include_framework: false,
                     force: false, output: $stdout)
        @index_dir = index_dir.to_s
        @output_dir = (output_dir || File.join(@index_dir, 'explorer')).to_s
        @reader = reader || build_reader
        @include_framework = include_framework
        @force = force
        @output = output
      end

      # Builds the payload and writes the explorer site.
      #
      # @return [Hash] stats — :path, :nodes, :edges, :skipped_units, :skipped_edges
      def export_all
        guard_ownership!
        builder = DataBuilder.new(reader: @reader, include_framework: @include_framework)
        payload = builder.build
        write_site(payload)
        log "Explorer written to #{File.join(@output_dir, 'index.html')}"
        { path: @output_dir,
          nodes: payload['nodes'].size,
          edges: payload['edges'].size }.merge(builder.stats)
      end

      private

      def build_reader
        require 'woods/mcp/index_reader'
        Woods::MCP::IndexReader.new(@index_dir)
      rescue ArgumentError => e
        raise ExportError, "#{e.message} — run `bundle exec rake woods:extract` first"
      end

      # Refuses to write into a non-empty directory that isn't explorer-owned
      # (no sentinel). An empty or absent directory is always fair game.
      def guard_ownership!
        return unless Dir.exist?(@output_dir)

        entries = Dir.children(@output_dir) - [SENTINEL]
        return if entries.empty? || File.exist?(File.join(@output_dir, SENTINEL)) || @force

        raise ExportError,
              "#{@output_dir} exists and was not created by the explorer " \
              '(no .woods-explorer sentinel). Set WOODS_EXPLORER_FORCE=1 to overwrite.'
      end

      def write_site(payload)
        # Sentinel first: if a later write crashes mid-run, the directory
        # still carries the ownership marker, so the next run self-heals
        # instead of tripping the foreign-directory guard.
        Woods::AtomicFile.write(File.join(@output_dir, SENTINEL), sentinel_body)
        Woods::AtomicFile.write(File.join(@output_dir, 'index.html'), render_html(payload))
        Woods::AtomicFile.write(File.join(@output_dir, 'data.json'),
                                "#{JSON.pretty_generate(payload)}\n")
        Woods::AtomicFile.write(File.join(@output_dir, 'README.md'), readme)
      end

      def render_html(payload)
        html = asset('template.html')
        replacements = {
          '/*__WOODS_STYLE__*/' => asset('style.css'),
          '/*__WOODS_APP__*/' => asset('app.js'),
          '__WOODS_DATA__' => embedded_json(payload)
        }
        replacements.each do |token, content|
          html = html.sub(token) { content }
        end
        html
      end

      # JSON destined for a <script type="application/json"> block. "</" can
      # terminate the block, and per the HTML tokenizer's double-escaped
      # states a "<!--" followed by "<script" can keep it open past the real
      # closer — so all three sequences are neutralized with JSON-legal
      # escapes ("<\/" and "\u003C") that parse back to the original text.
      def embedded_json(payload)
        JSON.generate(payload)
            .gsub('</', '<\/')
            .gsub('<!--', '\u003C!--')
            .gsub(/<script/i) { |m| "\\u003C#{m[1..]}" }
      end

      def asset(name)
        File.read(File.join(ASSETS_DIR, name), encoding: 'UTF-8')
      end

      def readme
        <<~MD
          # Woods Explorer

          Generated by `rake woods:explore` (gem: woods). Safe to delete —
          regenerate any time from the extraction index.

          - `index.html` — the interactive explorer. Self-contained: open it
            directly in a browser (`file://` works), or serve the directory
            statically (`ruby -run -e httpd . -p 8000`).
          - `data.json` — the full graph payload (`woods-explorer/1` schema):
            `nodes` (units with per-type facts), `edges` (`[source_index,
            target_index, via]` triples), `analysis` (orphans/hubs/cycles/
            bridges), `types`, `via_counts`, and `app` provenance. Intended
            for AI agents and scripts; see docs/EXPLORER.md in the woods gem.
        MD
      end

      def sentinel_body
        "woods-managed explorer output — regenerated by `rake woods:explore`. Safe to delete.\n"
      end

      def log(message)
        @output&.puts(message)
      end
    end
  end
end
