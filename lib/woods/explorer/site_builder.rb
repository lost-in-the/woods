# frozen_string_literal: true

require 'json'
require 'woods/atomic_file'
require 'woods/explorer/errors'
require 'woods/explorer/data_builder'
require 'woods/explorer/flow_digest'

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

      # Above this many bytes of compacted flow-op JSON, the ops move to a
      # flows.js sidecar loaded via <script src> (which, unlike fetch(), works
      # from file://). Below it, everything stays in the single index.html.
      FLOW_EMBED_LIMIT = 1_500_000

      # @param index_dir [String] extraction output directory (has manifest.json)
      # @param output_dir [String, nil] destination (default: index_dir/explorer)
      # @param reader [Woods::MCP::IndexReader, nil] injectable for tests
      # @param include_framework [Boolean] include rails_source nodes
      # @param force [Boolean] overwrite a foreign non-empty output directory
      # @param labels_path [String, nil] optional woods_labels.yml with plain
      #   names for screens/domains (default: <index_dir>/woods_labels.yml)
      # @param output [IO, nil] progress stream
      def initialize(index_dir:, output_dir: nil, reader: nil, include_framework: false,
                     force: false, labels_path: nil, output: $stdout)
        @index_dir = index_dir.to_s
        @output_dir = (output_dir || File.join(@index_dir, 'explorer')).to_s
        @reader = reader || build_reader
        @include_framework = include_framework
        @force = force
        @labels_path = labels_path || File.join(@index_dir, 'woods_labels.yml')
        @output = output
      end

      # Builds the payload and writes the explorer site.
      #
      # @return [Hash] stats — :path, :nodes, :edges, :skipped_units, :skipped_edges
      def export_all
        guard_ownership!
        digest = FlowDigest.new(@index_dir)
        unless digest.available?
          log 'NOTE: no flows/ directory in the index — Trace views will be limited. ' \
              'Enable `config.precompute_flows = true` and re-extract for full request flows.'
        end
        builder = DataBuilder.new(reader: @reader, include_framework: @include_framework,
                                  flow_digest: digest.build,
                                  labels: ScreenBuilder.load_labels(@labels_path))
        payload = builder.build
        write_site(payload)
        log "Explorer written to #{File.join(@output_dir, 'index.html')}"
        { path: @output_dir,
          nodes: payload['nodes'].size,
          edges: payload['edges'].size,
          screens: payload['screens'].size,
          flows: payload['flows']['summaries'].size }.merge(builder.stats)
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
        embedded, flows_js = package_flows(payload)
        Woods::AtomicFile.write(File.join(@output_dir, 'index.html'), render_html(embedded, flows_js))
        Woods::AtomicFile.write(File.join(@output_dir, 'flows.js'), flows_js) if flows_js
        Woods::AtomicFile.write(File.join(@output_dir, 'data.json'),
                                "#{JSON.pretty_generate(payload)}\n")
        Woods::AtomicFile.write(File.join(@output_dir, 'README.md'), readme)
      end

      # Splits flow_ops out of the embedded payload when it would bloat
      # index.html past FLOW_EMBED_LIMIT. The sidecar loads via <script src>
      # (which, unlike fetch(), works from file://); data.json always carries
      # everything.
      #
      # @return [Array(Hash, String | nil)] payload for embedding + flows.js body
      def package_flows(payload)
        ops_json = escape_script(JSON.generate(payload['flow_ops']))
        return [payload, nil] if ops_json.bytesize <= FLOW_EMBED_LIMIT

        slim = payload.dup
        slim['flow_ops'] = 'external:flows.js'
        [slim, "window.WOODS_FLOWOPS = #{ops_json};\n"]
      end

      def render_html(payload, flows_js)
        html = asset('template.html')
        replacements = {
          '/*__WOODS_STYLE__*/' => asset('style.css'),
          '/*__WOODS_APP__*/' => asset('app.js'),
          '__WOODS_DATA__' => embedded_json(payload),
          '<!--__WOODS_FLOWS__-->' => (flows_js ? '<script src="flows.js"></script>' : '')
        }
        replacements.each do |token, content|
          raise ExportError, "template is missing the #{token} token" unless html.include?(token)

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
        escape_script(JSON.generate(payload))
      end

      def escape_script(json)
        json.gsub('</', '<\/')
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
          - `data.json` — the full payload (`woods-explorer/2` schema):
            `nodes` (units with per-type facts), `edges` (`[source_index,
            target_index, via]` triples), `screens`, `flows` (summaries +
            inverted indexes), `flow_ops`, `analysis`, `types`, `via_counts`,
            and `app` provenance. Intended for AI agents and scripts; see
            docs/EXPLORER.md in the woods gem.
          - `flows.js` — present only for large apps: the compacted flow
            operation trees, split out so index.html stays lean.
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
