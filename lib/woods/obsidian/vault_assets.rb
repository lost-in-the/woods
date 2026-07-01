# frozen_string_literal: true

require 'json'

module Woods
  module Obsidian
    # Generates the static-ish vault configuration files: the `.obsidian/`
    # settings Obsidian reads (app.json, types.json, graph.json) and the
    # `Units.base` Obsidian Bases view.
    #
    # Grounded in Steph Ango's published vault conventions and the official
    # Obsidian docs:
    # - `app.json` only governs links Obsidian *generates*; our authored
    #   `[[path|alias]]` links resolve regardless. We still set absolute-path
    #   wikilinks as a courtesy for the user's future edits.
    # - We deliberately do NOT ship `core-plugins.json` — graph and Bases are
    #   enabled by default, and a partial plugin list could disable other
    #   defaults.
    # - `types.json` types the properties so Bases columns sort numerically
    #   (pagerank/counts) and tags render as tags.
    # - `graph.json` color groups apply to the *global* graph only (local-graph
    #   colors live in volatile workspace.json, which must not be shipped).
    module VaultAssets
      module_function

      # Palette of 24-bit RGB ints assigned to type tags in sorted order so the
      # graph coloring is deterministic across runs.
      PALETTE = [
        0xE5_5A_5A, 0x5A_9B_E5, 0x5A_E5_8B, 0xE5_C8_5A, 0xB4_5A_E5,
        0x5A_E5_D6, 0xE5_8B_5A, 0x8B_E5_5A, 0xE5_5A_B4, 0x5A_6B_E5
      ].freeze

      PROPERTY_TYPES = {
        'id' => 'text', 'type' => 'text', 'file' => 'text', 'source_hash' => 'text',
        'pagerank' => 'number', 'dependency_count' => 'number', 'dependent_count' => 'number',
        'tags' => 'tags', 'aliases' => 'aliases'
      }.freeze

      # @return [String] .obsidian/app.json
      def app_json
        pretty(
          'newLinkFormat' => 'absolute',
          'useMarkdownLinks' => false,
          'alwaysUpdateLinks' => true
        )
      end

      # @return [String] .obsidian/types.json (property -> type registry)
      def types_json
        pretty('types' => PROPERTY_TYPES)
      end

      # @param types [Array<String>] singular unit types present in the vault
      # @return [String] .obsidian/graph.json with per-type color groups
      def graph_json(types)
        groups = Array(types).uniq.sort.each_with_index.map do |type, i|
          { 'query' => "tag:#woods/#{type}", 'color' => { 'a' => 1, 'rgb' => PALETTE[i % PALETTE.size] } }
        end
        pretty('colorGroups' => groups, 'showTags' => true, 'showAttachments' => false)
      end

      # @return [String] Units.base — an Obsidian Bases view (YAML)
      def units_base
        <<~YAML
          filters:
            and:
              - 'file.hasTag("woods/unit")'
          properties:
            type:
              displayName: Type
            pagerank:
              displayName: PageRank
            dependent_count:
              displayName: Used by
            dependency_count:
              displayName: Depends on
          views:
            - type: table
              name: All units
              groupBy: type
              order:
                - file.name
                - type
                - pagerank
                - dependent_count
                - dependency_count
            - type: table
              name: Hubs
              filters:
                and:
                  - 'file.hasTag("woods/hub")'
              order:
                - file.name
                - dependent_count
                - pagerank
        YAML
      end

      def pretty(hash)
        "#{JSON.pretty_generate(hash)}\n"
      end
    end
  end
end
