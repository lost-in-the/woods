# frozen_string_literal: true

require 'set'
require 'json'
require 'yaml'
require 'pathname'
require 'woods'
require 'woods/atomic_file'
require_relative 'errors'
require_relative 'name_mapper'
require_relative 'note_builder'
require_relative 'vault_assets'

module Woods
  module Obsidian
    # Orchestrates exporting Woods extraction output to a self-contained
    # Obsidian vault.
    #
    # Reads the flat extraction directory via IndexReader (using raw_graph_data,
    # so string keys + persisted pagerank), then writes:
    #   - one Markdown note per exported unit (NoteBuilder),
    #   - per-type `_index.md` MOCs + a root `_Overview.md`,
    #   - a `_woods/` machine sidecar (id<->path manifest + verbatim graph copies),
    #   - `.obsidian/` config + `Units.base` (only into a woods-owned vault),
    #   - a `.woods-vault` ownership sentinel.
    # Finally it sweeps stale woods-managed notes — guarded so it can never
    # delete a user's own notes or run against a foreign vault.
    #
    # All dependency edges come from one in-memory edge_map (the graph's
    # edges/reverse); per-unit JSON is read only for note bodies.
    #
    # @example
    #   Woods::Obsidian::VaultExporter.new(
    #     index_dir: "tmp/woods", vault_path: "tmp/woods/obsidian_vault"
    #   ).export_all
    #   # => { exported: 412, indexes: 19, swept: 3, skipped: 0, errors: [] }
    class VaultExporter
      MAX_ERRORS = 100
      PURGE_GUARD_FRACTION = 0.30
      PURGE_GUARD_MIN_DOCS = 10
      SENTINEL = '.woods-vault'
      SIDECAR_DIR = '_woods'
      FRAMEWORK_TYPES = %w[rails_source gem_source].freeze
      # Upper bound on frontmatter lines scanned when identifying a managed note
      # during the sweep — our frontmatter is ~12 lines; this just bounds work on
      # a malformed file that opens with "---" but never closes the fence.
      MAX_FRONTMATTER_LINES = 200

      # @param index_dir [String] extraction output directory to read
      # @param vault_path [String] directory to write the vault into
      # @param config [Configuration] Woods configuration (default: global)
      # @param reader [Object, nil] IndexReader (auto-created if nil)
      # @param include_source [Boolean] embed credential-scrubbed source in notes
      # @param include_framework [Boolean] include rails_source units
      # @param force_purge [Boolean] bypass the mass-deletion sweep guard
      # @param output [IO] progress stream
      def initialize(index_dir:, vault_path:, config: Woods.configuration, reader: nil,
                     include_source: false, include_framework: false, force_purge: false, output: $stdout)
        @config = config
        @vault = Pathname.new(vault_path.to_s)
        @reader = reader || build_reader(index_dir)
        @include_source = include_source
        @include_framework = include_framework
        @force_purge = force_purge
        @output = output
      end

      # Generate the full vault. Idempotent: re-running against an unchanged
      # extraction produces byte-identical output.
      #
      # @return [Hash] { exported:, indexes:, swept:, skipped:, errors: }
      def export_all
        graph = @reader.raw_graph_data || {}
        @nodes = graph['nodes'] || {}
        @pagerank = graph['pagerank'] || {}
        analysis = safe_graph_analysis
        owned = vault_owned_at_start?

        emitted, skipped = partition_emitted
        mapper = build_mapper(emitted)
        edge_map = build_edge_map(emitted.to_set, graph)
        builder = build_note_builder(mapper, analysis)

        written = Set.new
        errors = []
        exported = write_notes(emitted, mapper, edge_map, builder, written, errors)
        indexes = write_indexes(emitted, mapper, written)
        write_sidecar(emitted, mapper, graph, analysis, written)
        write_owned_assets(emitted) if owned

        swept = owned && errors.empty? ? sweep(written) : 0
        warn_foreign unless owned
        { exported: exported, indexes: indexes, swept: swept, skipped: skipped, errors: cap_errors(errors) }
      end

      private

      # ── Selection / mapping ──────────────────────────────────────────

      # The emitted set = graph nodes of an exportable type that have a loadable
      # unit file. Confirming the file loads (not just that the index lists it)
      # guarantees every wikilink target is backed by a real note — a node listed
      # in the index but with no readable unit is dropped (counted as skipped).
      #
      # @return [Array(Array<String>, Integer)] [sorted emitted ids, skipped count]
      def partition_emitted
        known = known_ids
        candidates = @nodes.keys.select do |id|
          type = @nodes[id]['type']
          next false if !@include_framework && FRAMEWORK_TYPES.include?(type)

          known.include?(id)
        end.sort

        # Load each candidate once and keep it: confirms the unit is readable
        # (a corrupt/missing file is skipped, not fatal) and lets Pass 2 render
        # from this cache instead of re-reading every file past the reader's
        # small LRU — avoiding ~2x disk reads + JSON parses on a large vault.
        # Holding the units for one batch export is an acceptable memory trade.
        @units = {}
        skipped = 0
        candidates.each do |id|
          unit = load_unit(id)
          unit ? (@units[id] = unit) : (skipped += 1)
        end
        [@units.keys, skipped]
      end

      # Load a unit, treating an unreadable/corrupt file as absent rather than
      # letting one bad JSON parse abort the whole export.
      def load_unit(id)
        @reader.find_unit(id)
      rescue StandardError => e
        log "  skipped #{id}: #{e.class}: #{e.message}"
        nil
      end

      def known_ids
        @known_ids ||= @reader.list_units.to_set { |entry| entry['identifier'] }
      end

      def build_mapper(emitted)
        NameMapper.new(emitted.to_h { |id| [id, dir_for(@nodes[id]['type'])] })
      end

      def dir_for(type)
        require 'woods/mcp/index_reader'
        Woods::MCP::IndexReader::TYPE_TO_DIR[type] || "#{type}s"
      end

      def build_note_builder(mapper, analysis)
        NoteBuilder.new(name_mapper: mapper, nodes: @nodes, pagerank: @pagerank,
                        analysis: analysis, include_source: @include_source, scanner: scanner)
      end

      # The single edge source: per-id forward (depends_on) and reverse (used_by)
      # edges from the graph, filtered to the emitted set, self-edges dropped.
      def build_edge_map(emitted, graph)
        edges = graph['edges'] || {}
        reverse = graph['reverse'] || {}
        emitted.each_with_object({}) do |id, map|
          deps = Array(edges[id]).filter_map { |edge| forward_edge(edge, id, emitted) }
                                 .uniq { |edge| [edge[:target], edge[:via]] }
          used = Array(reverse[id]).select { |sid| sid != id && emitted.include?(sid) }.uniq
          map[id] = { depends_on: deps, used_by: used }
        end
      end

      def forward_edge(edge, source_id, emitted)
        edge = { 'target' => edge } unless edge.is_a?(Hash)
        target = edge['target']
        return nil if target == source_id || !emitted.include?(target)

        { target: target, via: edge['via'] }
      end

      # ── Pass 2: notes ────────────────────────────────────────────────

      def write_notes(emitted, mapper, edge_map, builder, written, errors)
        exported = 0
        emitted.each do |id|
          unit = @units[id]
          next unless unit # defensive — partition_emitted already cached loadable units

          edges = edge_map[id] || { depends_on: [], used_by: [] }
          note = builder.build(id: id, unit: unit, depends_on: edges[:depends_on], used_by: edges[:used_by])
          next if note.nil?

          rel = mapper.path_for(id)
          AtomicFile.write(@vault.join(rel), note)
          written << rel
          exported += 1
        rescue StandardError => e
          errors << "#{id}: #{e.class}: #{e.message}"
        end
        exported
      end

      # ── Pass 3a: MOC + overview ──────────────────────────────────────

      def write_indexes(emitted, mapper, written)
        by_dir = emitted.group_by { |id| File.dirname(mapper.path_for(id)) }
        by_dir.sort.each do |dir, ids|
          write_managed(written, "#{dir}/_index.md", moc_note(dir, ids, mapper))
        end
        write_managed(written, '_Overview.md', overview_note(by_dir))
        by_dir.size + 1
      end

      def moc_note(dir, ids, mapper)
        lines = [managed_frontmatter, "# #{dir} (#{ids.size})", '']
        ids.sort.each { |id| lines << "- #{mapper.wikilink(id)}" }
        "#{lines.join("\n")}\n"
      end

      def overview_note(by_dir)
        total = by_dir.values.sum(&:size)
        lines = [managed_frontmatter, '# Woods Vault Overview', '',
                 "#{total} units across #{by_dir.size} types.", '', '## Units by type']
        by_dir.sort.each { |dir, ids| lines << "- [[#{dir}/_index|#{dir}]] — #{ids.size}" }
        lines.push('', '## Machine-readable',
                   '- `_woods/manifest.json` — id ↔ path map + per-note metadata',
                   '- `_woods/dependency_graph.json` / `_woods/graph_analysis.json` — full topology')
        "#{lines.join("\n")}\n"
      end

      def managed_frontmatter
        "#{{ 'woods_managed' => true, 'tags' => ['woods/moc'] }.to_yaml}---"
      end

      # ── Pass 3b: machine sidecar ─────────────────────────────────────

      def write_sidecar(emitted, mapper, graph, analysis, written)
        notes = emitted.to_h do |id|
          [id, { 'path' => mapper.path_for(id), 'type' => @nodes[id]['type'],
                 'pagerank' => @pagerank[id]&.round(6) }.compact]
        end
        manifest = { 'schema_version' => 1, 'notes' => sort_hash(notes), 'paths' => sort_hash(mapper.paths_to_ids) }
        write_json(written, "#{SIDECAR_DIR}/manifest.json", manifest)
        write_json(written, "#{SIDECAR_DIR}/dependency_graph.json", graph)
        write_json(written, "#{SIDECAR_DIR}/graph_analysis.json", analysis) if analysis
      end

      # ── Pass 3c: owned-only assets (.obsidian config, Units.base, sentinel) ──

      def write_owned_assets(emitted)
        if can_write_obsidian_config?
          AtomicFile.write(@vault.join('.obsidian', 'app.json'), VaultAssets.app_json)
          AtomicFile.write(@vault.join('.obsidian', 'types.json'), VaultAssets.types_json)
          AtomicFile.write(@vault.join('.obsidian', 'graph.json'), VaultAssets.graph_json(present_types(emitted)))
          AtomicFile.write(@vault.join('Units.base'), VaultAssets.units_base)
        end
        AtomicFile.write(@vault.join(SENTINEL),
                         "woods-managed vault — regenerated by `rake woods:obsidian`. Safe to delete.\n")
      end

      def can_write_obsidian_config?
        obsidian = @vault.join('.obsidian')
        return true unless obsidian.exist?
        return true if @vault.join(SENTINEL).exist?

        log '  existing .obsidian/ left untouched (not a woods-owned vault)'
        false
      end

      def present_types(emitted)
        emitted.map { |id| @nodes[id]['type'] }.uniq
      end

      # ── Pass 4: guarded sweep ────────────────────────────────────────

      def sweep(written)
        managed = managed_notes
        stale = managed.reject { |rel| written.include?(rel) }
        return 0 if stale.empty?
        return 0 if guard_blocks_purge?(stale, managed)

        stale.sort.count do |rel|
          path = @vault.join(rel)
          next false unless safe_inside_vault?(path) && path.file?

          File.delete(path)
          true
        end
      end

      def managed_notes
        Dir.glob(@vault.join('**', '*.md')).filter_map do |abs|
          next unless managed_marker?(abs)

          Pathname.new(abs).relative_path_from(@vault).to_s
        end
      end

      # Only our notes carry this frontmatter flag. Reads just the frontmatter
      # head (notes can be large when include_source is on) rather than the whole
      # file, and bails on anything that isn't a leading "---" fence.
      def managed_marker?(abs)
        fm = frontmatter_head(abs)
        fm.is_a?(Hash) && fm['woods_managed'] == true
      rescue StandardError
        false
      end

      def frontmatter_head(abs)
        File.open(abs, 'r:UTF-8') do |file|
          return nil unless file.gets == "---\n"

          lines = []
          MAX_FRONTMATTER_LINES.times do
            line = file.gets
            break if line.nil?
            return YAML.safe_load(lines.join) if line == "---\n"

            lines << line
          end
          nil
        end
      end

      def guard_blocks_purge?(stale, managed)
        return false if @force_purge

        total = managed.size
        return false if total < PURGE_GUARD_MIN_DOCS

        fraction = stale.size.to_f / total
        return false unless fraction > PURGE_GUARD_FRACTION

        log "  WARNING: refusing to delete #{stale.size}/#{total} managed notes " \
            "(#{(fraction * 100).round}% > #{(PURGE_GUARD_FRACTION * 100).to_i}%). " \
            'Set WOODS_OBSIDIAN_FORCE_PURGE=1 to override.'
        true
      end

      def safe_inside_vault?(path)
        root = @vault.realpath.to_s
        target = path.exist? ? path.realpath.to_s : path.expand_path.to_s
        target == root || target.start_with?(root + File::SEPARATOR)
      rescue StandardError
        false
      end

      # ── Ownership ────────────────────────────────────────────────────

      def vault_owned_at_start?
        return true unless @vault.exist?
        return true if @vault.join(SENTINEL).exist?

        (@vault.children.map { |c| c.basename.to_s } - [SENTINEL]).empty?
      end

      def warn_foreign
        log "  WARNING: #{@vault} is not a woods-owned vault (no #{SENTINEL} sentinel and it " \
            'already has content). Wrote notes additively; skipped config and the stale-note sweep.'
      end

      # ── Helpers ──────────────────────────────────────────────────────

      def write_managed(written, rel, content)
        AtomicFile.write(@vault.join(rel), content)
        written << rel
      end

      def write_json(written, rel, data)
        AtomicFile.write(@vault.join(rel), "#{JSON.pretty_generate(data)}\n")
        written << rel
      end

      def sort_hash(hash)
        hash.sort.to_h
      end

      def scanner
        return nil unless @include_source

        @scanner ||= begin
          require 'woods/console/credential_scanner'
          Woods::Console::CredentialScanner.new
        end
      end

      def safe_graph_analysis
        @reader.graph_analysis
      rescue StandardError
        nil
      end

      def build_reader(index_dir)
        require 'woods/mcp/index_reader'
        Woods::MCP::IndexReader.new(index_dir)
      rescue ArgumentError => e
        raise ExportError, "#{e.message} — run `bundle exec rake woods:extract` first"
      end

      def cap_errors(errors)
        return errors if errors.size <= MAX_ERRORS

        errors.first(MAX_ERRORS) + ["... and #{errors.size - MAX_ERRORS} more errors"]
      end

      def log(message)
        @output&.puts(message)
      end
    end
  end
end
