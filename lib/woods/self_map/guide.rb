# frozen_string_literal: true

require_relative 'markdown'

module Woods
  module SelfMap
    # Bounded filesystem orientation from summaries, without decoding source bodies.
    class Guide
      LIMIT = 8

      def initialize(snapshot, inventory, root:)
        @snapshot = snapshot
        @inventory = inventory
        @root = root
      end

      def files
        groups = @snapshot.entries.group_by { |entry| area(entry) }
        pages = groups.to_h { |name, entries| ["areas/#{slug(name)}.md", area_page(name, entries)] }
        pages.merge('START_HERE.md' => start_page(groups),
                    'inventory.json' => JSON.pretty_generate('units' => @snapshot.entries, 'inputs' => @inventory))
      end

      private

      def area(entry)
        directory = File.dirname(entry.fetch('file_path'))
        directory.split('/').first(directory.start_with?('lib/woods/') ? 3 : 2).join('/')
      end

      def slug(name)
        Digest::SHA256.hexdigest(name)[0, 16]
      end

      def area_page(name, entries)
        files = entries.select { |entry| entry['type'] == 'ruby_file' }.map { |entry| entry['file_path'] }.sort
        definitions = entries.select { |entry| entry['definition'] }
        ["# #{Markdown.escape(name)}", '', 'Filesystem grouping; static evidence, not a runtime boundary.', '',
         '## Files (alphabetical sample)', '', *files.first(LIMIT).map { |path| "- #{Markdown.link(@root, path)}" }, '',
         '## Definitions (alphabetical sample)', '', *definitions.first(LIMIT).map do |entry|
           "- #{Markdown.escape(entry['identifier'])} [#{entry['type']}] — #{Markdown.link(@root, entry['file_path'])}"
         end, '', 'Samples are bounded to eight per list. Full inventory: [inventory.json](../inventory.json).',
         'No recorded dependents does not establish unused code or low change risk.', ''].join("\n")
      end

      def start_page(groups)
        [*intro, '', '## Areas', '', '| Area | Listed units |', '| --- | ---: |',
         *groups.sort.map do |name, entries|
           "| [#{Markdown.escape(name)}](areas/#{slug(name)}.md) | #{entries.size} |"
         end,
         '', *coverage, ''].join("\n")
      end

      def intro
        ['# Woods development context', '',
         "Generation: #{@snapshot.reader.generation_number}; source: #{@snapshot.provenance['source_checksum']}.",
         'Covered sources matched before publication; rerun after edits. Opening this file does not recheck freshness.',
         '', 'This is a static source map. Runtime behavior and executed line/branch coverage are not established.', '',
         '## Workflow', '', '1. Read policy and use the area index to find source.',
         '2. Run `bin/rake woods:self_docs` to refresh this guide.',
         '3. Run `bin/rake "woods:self_impact[path/to/file.rb]"` for candidate impact and suggested specs.',
         '4. Inspect witness paths and run the required validation lanes.', '',
         "Policy: #{Markdown.link(@root, 'AGENTS.md')}; validation: #{Markdown.link(@root, 'CONTRIBUTING.md')}; " \
         "docs: #{Markdown.link(@root, 'docs/README.md')}."]
      end

      def coverage
        counts = @inventory['files'].group_by { |file| file['mode'] }.transform_values(&:size)
        ['## Coverage and limits', '', "Input universe: #{@inventory['scope']}; file states: #{counts.to_json}.",
         "Parse failures: #{@snapshot.health.fetch('parse_failures', []).size}; " \
         'reference_only means no published test body.',
         'Unmapped files, dynamic calls and unexecuted branches remain unknown.',
         'No baseline is inferred from the previous generation. Deleted paths require an explicitly selected baseline.',
         'Inventory and diagnostics: [inventory.json](inventory.json); provenance: [manifest.json](manifest.json).']
      end
    end
  end
end
