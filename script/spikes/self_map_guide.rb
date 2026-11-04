# frozen_string_literal: true

# One-shot documentation experiment over an existing pinned self-map.
# bundle exec ruby script/spikes/self_map_guide.rb INDEX_DIR OUTPUT_PARENT
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../../lib/woods/published_index'

module SelfMapGuideSpike
  ROOT = File.expand_path(ENV.fetch('WOODS_GUIDE_SOURCE_ROOT', File.expand_path('../..', __dir__)))
  LIMIT = 8

  def self.area(entry)
    directory = File.dirname(entry.fetch('file_path'))
    depth = directory.start_with?('lib/woods/') ? 3 : 2
    directory.split('/').first(depth).join('/')
  end

  def self.source_link(path)
    "[#{path}](#{File.join(ROOT, path)})"
  end

  def self.area_page(name, entries)
    files = entries.select { |entry| entry['type'] == 'ruby_file' }.map { |entry| entry['file_path'] }.sort
    definitions = definitions_in(entries)
    ["# #{name}", '', 'Filesystem grouping; static inventory, not a runtime boundary.', '',
     "#{entries.size} units; #{files.size} source/spec files; #{definitions.size} class/module definitions.", '',
     '## Starting files (alphabetical sample)', '', *files.first(LIMIT).map { |path| "- #{source_link(path)}" }, '',
     '## Definitions (alphabetical sample)', '',
     *definition_lines(definitions), '', 'Samples are bounded. See inventory.json for every entry in this generation.',
     'Read source before editing; spec references do not establish execution or test coverage.'].push('').join("\n")
  end

  def self.definitions_in(entries)
    entries.select { |entry| %w[ruby_class ruby_module].include?(entry['type']) }
  end

  def self.definition_lines(definitions)
    definitions.sort_by { |entry| entry['identifier'] }.first(LIMIT).map do |entry|
      "- `#{entry['identifier']}` [#{entry['type']}] — #{source_link(entry['file_path'])}"
    end
  end

  def self.start_page(index, groups)
    manifest = index.manifest
    (intro(index) + [
      '## How to use this map', '',
      '1. Read the repository policy before making a change.',
      '2. Find the filesystem area below, then inspect its starting files and definitions.',
      '3. Refresh with `bin/rake woods:self_map` before an impact query.',
      '4. Use `bin/rake "woods:affected_specs[path/to/changed.rb]"` for static suggestions.',
      '5. Check exclusions and choose the required validation lanes from CONTRIBUTING.md.', '',
      "Policy: #{source_link('AGENTS.md')}; validation: #{source_link('CONTRIBUTING.md')}; " \
      "canonical docs: #{source_link('docs/README.md')}.", '',
      '## Areas', '', '| Area | Units |', '| --- | ---: |',
      *groups.sort.map { |name, entries| "| [#{name}](areas/#{slug(name)}.md) | #{entries.size} |" }, ''
    ] + limits(manifest)).push('').join("\n")
  end

  def self.limits(manifest)
    ['## Scope and limits', '',
     "Included: `#{Array(manifest.dig('provenance', 'included')).join('`, `')}`.",
     "Reference-only: `#{Array(manifest.dig('provenance', 'references_only')).join('`, `')}`.",
     "Excluded: `#{Array(manifest.dig('provenance', 'excluded')).join('`, `')}`.",
     'Unlisted paths have no coverage claim. A file inventory entry does not prove that parsing succeeded.',
     'No dependents does not prove no callers. Consult retained earlier generations for deleted code.',
     'No runtime, line/branch, per-example or cross-version test coverage is asserted.']
  end

  def self.intro(index)
    [
      '# Woods development map', '',
      "Generation: #{index.generation_number}; " \
      "source checksum: `#{index.manifest.dig('provenance', 'source_checksum')}`.", '',
      '**Freshness: not checked against the working tree.** This is a pinned static snapshot.',
      'Parse completeness, dynamic dispatch and test execution coverage are unknown.', ''
    ]
  end

  def self.slug(name)
    name.tr('/', '-')
  end

  def self.write_manifest(index, areas, units, output)
    data = { schema_version: 1, generation: index.generation_number,
             source_checksum: index.manifest.dig('provenance', 'source_checksum'),
             freshness: 'not_checked', area_count: areas, units: units }
    File.write(File.join(output, 'manifest.json'), JSON.pretty_generate(data))
  end

  def self.render(index_dir, output_parent)
    FileUtils.mkdir_p(output_parent)
    Woods::PublishedIndex.open(index_dir) do |index|
      entries = index.units
      groups = entries.group_by { |entry| area(entry) }
      output = Dir.mktmpdir("guide-gen#{index.generation_number}-", output_parent)
      FileUtils.mkdir_p(File.join(output, 'areas'))
      groups.each do |name, units|
        File.write(File.join(output, 'areas', "#{slug(name)}.md"), area_page(name, units))
      end
      File.write(File.join(output, 'inventory.json'), JSON.pretty_generate(entries))
      File.write(File.join(output, 'START_HERE.md'), start_page(index, groups))
      write_manifest(index, groups.size, entries.size, output)
      output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: self_map_guide.rb INDEX_DIR OUTPUT_PARENT' unless ARGV.size == 2
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts SelfMapGuideSpike.render(*ARGV)
  warn "Guide rendered in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)}s"
end
