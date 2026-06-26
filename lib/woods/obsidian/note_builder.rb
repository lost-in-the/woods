# frozen_string_literal: true

require 'set'
require 'yaml'

module Woods
  module Obsidian
    # Renders one extracted unit into a single Obsidian note: flat YAML
    # frontmatter (the machine-queryable surface) followed by a Markdown body
    # with wikilinks (the human surface).
    #
    # Two invariants from the design:
    # - **Edges come from the graph, not the unit.** The authoritative "Depends
    #   on" / "Used by" sections are rendered from +depends_on+/+used_by+ passed
    #   in by the exporter (derived from the dependency graph). The "Associations"
    #   section is an explicit, human-only nicety read from unit metadata and is
    #   not part of the machine edge contract.
    # - **Frontmatter is flat.** Obsidian's Properties UI cannot represent nested
    #   objects, so only scalars and flat lists go in YAML; structured edges live
    #   in the +_woods/+ sidecar. Frontmatter is emitted via Psych so any
    #   identifier (quotes, colons, hashes, newlines) is escaped correctly.
    class NoteBuilder
      # Cap on how many "Used by" links a single note renders before summarizing,
      # so a hub with hundreds of dependents doesn't dominate the note or graph.
      USED_BY_DISPLAY_CAP = 50

      ASSOCIATION_ORDER = %w[belongs_to has_one has_many has_and_belongs_to_many].freeze

      # @param name_mapper [NameMapper] resolves ids to wikilinks/paths
      # @param nodes [Hash] graph nodes ({ id => { 'type' => , ... } }) for edge-endpoint types
      # @param pagerank [Hash{String=>Float}] persisted pagerank scores
      # @param analysis [Hash, nil] parsed graph_analysis.json (hubs/cycles/orphans/bridges) or nil
      # @param include_source [Boolean] embed scrubbed source code
      # @param scanner [#scan, nil] credential scanner (required when include_source)
      def initialize(name_mapper:, nodes:, pagerank: {}, analysis: nil, include_source: false, scanner: nil)
        @mapper = name_mapper
        @nodes = nodes || {}
        @pagerank = pagerank || {}
        @include_source = include_source
        @scanner = scanner
        @hubs = identifier_set(analysis, 'hubs')
        @bridges = identifier_set(analysis, 'bridges')
        @orphans = plain_set(analysis, 'orphans')
        @cycle_members = cycle_member_set(analysis)
      end

      # @param id [String] bare unit identifier (graph node key)
      # @param unit [Hash] parsed unit JSON (used only for body facts)
      # @param depends_on [Array<Hash>] [{ target:, via: }] filtered to the emitted set
      # @param used_by [Array<String>] dependent ids filtered to the emitted set
      # @return [String, nil] the note, or nil when an enabled source scrub failed (skip the write)
      def build(id:, unit:, depends_on:, used_by:)
        sections = [
          frontmatter(id, unit, depends_on, used_by),
          heading(id, unit),
          meta_line(unit),
          callout(id, used_by),
          depends_section(depends_on),
          used_by_section(used_by),
          associations_section(unit),
          source_section(unit)
        ].compact

        "#{sections.join("\n\n")}\n"
      end

      private

      # ── Frontmatter ──────────────────────────────────────────────────

      def frontmatter(id, unit, depends_on, used_by)
        fm = {
          'woods_managed' => true,
          'id' => id,
          'type' => unit['type'],
          'file' => unit['file_path'],
          'source_hash' => unit['source_hash'],
          'pagerank' => pagerank_for(id),
          'dependency_count' => depends_on.size,
          'dependent_count' => used_by.size,
          'tags' => tags_for(id, unit),
          'aliases' => [id]
        }.compact
        "#{fm.to_yaml}---"
      end

      def pagerank_for(id)
        score = @pagerank[id]
        score&.round(6)
      end

      def tags_for(id, unit)
        tags = ['woods/unit', "woods/#{unit['type']}"]
        tags << 'woods/hub' if @hubs.include?(id)
        tags << 'woods/orphan' if @orphans.include?(id)
        tags << 'woods/cycle' if @cycle_members.include?(id)
        tags << 'woods/bridge' if @bridges.include?(id)
        tags
      end

      # ── Body ─────────────────────────────────────────────────────────

      def heading(id, unit)
        "# #{unit['identifier'] || id}"
      end

      def meta_line(unit)
        meta = unit['metadata'] || {}
        parts = []
        parts << "**File:** `#{unit['file_path']}`" if unit['file_path']
        parts << "**LOC:** #{meta['loc']}" if meta['loc']
        parts << table_part(meta) if meta['table_name']
        parts.empty? ? nil : parts.join(' | ')
      end

      def table_part(meta)
        cols = meta['column_count'] || (meta['columns'] || []).size
        part = "**Table:** #{meta['table_name']}"
        part += " (#{cols} columns)" if cols.is_a?(Integer) && cols.positive?
        part
      end

      def callout(id, used_by)
        if @hubs.include?(id)
          pr = pagerank_for(id)
          suffix = pr ? " (PageRank #{format('%.4f', pr)})" : ''
          "> [!warning] Hub — high blast radius\n> #{used_by.size} units depend on this#{suffix}."
        elsif @cycle_members.include?(id)
          "> [!warning] Part of a dependency cycle\n> This unit participates in a circular dependency."
        end
      end

      def depends_section(depends_on)
        rows = depends_on.filter_map do |dep|
          target = dep[:target] || dep['target']
          via = dep[:via] || dep['via']
          link = @mapper.wikilink(target)
          next unless link

          [target.to_s, via.to_s, "- #{link}#{" — *#{via}*" if via}"]
        end
        return nil if rows.empty?

        lines = rows.sort_by { |target, via, _| [target, via] }.map(&:last)
        (['## Depends on'] + lines).join("\n")
      end

      def used_by_section(used_by)
        return nil if used_by.empty?

        shown = used_by.uniq.sort.first(USED_BY_DISPLAY_CAP)
        lines = ["## Used by (#{used_by.uniq.size})"]
        shown.group_by { |sid| @nodes.dig(sid, 'type') || 'other' }.sort.each do |type, sids|
          links = sids.sort.filter_map { |sid| @mapper.wikilink(sid) }
          lines << "**#{pluralize(type)}:** #{links.join(', ')}" unless links.empty?
        end
        more = used_by.uniq.size - shown.size
        lines << "*…and #{more} more (see graph)*" if more.positive?
        lines.join("\n")
      end

      def associations_section(unit)
        return nil unless unit['type'] == 'model'

        assocs = unit.dig('metadata', 'associations') || []
        return nil if assocs.empty?

        grouped = assocs.group_by { |a| a['type'] }
        lines = ['## Associations']
        ASSOCIATION_ORDER.each do |macro|
          rendered = render_associations(grouped[macro])
          lines << "**#{macro}:** #{rendered.join(', ')}" unless rendered.empty?
        end
        lines.size > 1 ? lines.join("\n") : nil
      end

      def render_associations(items)
        return [] unless items

        items.filter_map do |assoc|
          link = @mapper.wikilink(assoc['target'] || assoc['name'])
          next unless link

          dependent = assoc.dig('options', 'dependent')
          dependent ? "#{link} (dependent: #{dependent})" : link
        end.sort
      end

      # Renders the source block when enabled. If the credential scrub fails it
      # returns nil (omit the section) rather than shipping unscrubbed source —
      # the note is still written, just without its source block.
      def source_section(unit)
        return nil unless @include_source

        code = unit['source_code']
        return nil if code.nil? || code.to_s.empty?

        scrubbed = scrub(code)
        return nil if scrubbed.nil?

        "## Source\n\n```ruby\n#{scrubbed.chomp}\n```"
      end

      def scrub(code)
        return code unless @scanner

        scanned, = @scanner.scan(code)
        scanned
      rescue StandardError
        nil
      end

      # ── Analysis sets ────────────────────────────────────────────────

      def identifier_set(analysis, key)
        entries = analysis && analysis[key]
        return Set.new unless entries.is_a?(Array)

        entries.filter_map { |e| e.is_a?(Hash) ? e['identifier'] : e }.to_set
      end

      def plain_set(analysis, key)
        entries = analysis && analysis[key]
        entries.is_a?(Array) ? entries.to_set : Set.new
      end

      def cycle_member_set(analysis)
        cycles = analysis && analysis['cycles']
        return Set.new unless cycles.is_a?(Array)

        cycles.flatten.to_set
      end

      def pluralize(type)
        type.end_with?('y') ? "#{type[0..-2]}ies" : "#{type}s"
      end
    end
  end
end
