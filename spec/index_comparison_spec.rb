# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

RSpec.describe IndexComparison do
  # A flat (pre-payload) index: Generation resolves its payload to the root.
  def write_index(dir, note:)
    FileUtils.mkdir_p(File.join(dir, 'models'))
    FileUtils.mkdir_p(File.join(dir, 'flows'))
    unit = { 'identifier' => 'Widget', 'type' => 'model', 'source_code' => "class Widget # #{note}\nend\n",
             'extracted_at' => '2026-01-01T00:00:00Z' }
    File.write(File.join(dir, 'models', 'Widget.json'), JSON.generate(unit), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'models', '_index.json'),
               JSON.generate([{ 'identifier' => 'Widget', 'summary' => note }]), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'flows', 'flow_index.json'),
               JSON.generate('generated_at' => '2026', 'flows' => { 'name' => note }), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'manifest.json'),
               JSON.generate('total_units' => 1, 'total_chunks' => 1, 'note' => note), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'dependency_graph.json'),
               JSON.generate('nodes' => { 'Widget' => { 'note' => note } }), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'graph_analysis.json'), JSON.generate('orphans' => [note]), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'SUMMARY.md'), "# Woods Index #{note}\n\nUnits: 1 | Chunks: 1 | Categories: 1\n",
               encoding: Encoding::UTF_8)
  end

  it 'compares indexes holding multibyte text under a POSIX default external encoding' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'façade → ledger')
      write_index(right, note: 'façade → ledger')

      differences = with_posix_default_external { described_class.differences(left, right) }

      expect(differences).to eq([])
    end
  end

  it 'compares commit tables, tolerating only the window start day' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'same')
      write_index(right, note: 'same')
      table = { 'head' => 'a' * 40, 'since' => '2025-10-23', 'commits' => [], 'paths' => {} }
      File.write(File.join(left, 'git_commits.json'), JSON.generate(table))

      expect(described_class.differences(left, right)).to include(a_string_starting_with('git_commits.json'))

      File.write(File.join(right, 'git_commits.json'), JSON.generate(table.merge('since' => '2025-10-24')))
      expect(described_class.differences(left, right)).to eq([])

      File.write(File.join(right, 'git_commits.json'), JSON.generate(table.merge('head' => 'b' * 40)))
      expect(described_class.differences(left, right)).to include(a_string_starting_with('git_commits.json'))
    end
  end

  it 'still reports a multibyte difference under a POSIX default external encoding' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'façade')
      write_index(right, note: 'fassade')

      differences = with_posix_default_external { described_class.differences(left, right) }

      expect(differences).to include(a_string_starting_with('unit models/Widget.json field source_code'))
      # String#inspect escapes what the default external cannot show.
      expect(differences.join).to include('fa\\u00E7ade').and include('fassade')
    end
  end
end
