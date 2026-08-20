# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'yaml'
require 'pathname'
require 'stringio'
require 'woods/obsidian/vault_exporter'
# instance_double(Woods::MCP::IndexReader) only verifies when the constant
# is loaded; require it here so the spec passes standalone.
require 'woods/mcp/index_reader'

RSpec.describe Woods::Obsidian::VaultExporter do
  around do |example|
    Dir.mktmpdir do |dir|
      @vault = File.join(dir, 'vault')
      example.run
    end
  end

  let(:graph) do
    {
      'nodes' => {
        'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb' },
        'Account' => { 'type' => 'model', 'file_path' => 'app/models/account.rb' },
        'UsersController' => { 'type' => 'controller', 'file_path' => 'app/controllers/users_controller.rb' },
        'RailsThing' => { 'type' => 'rails_source' }
      },
      'edges' => {
        'User' => [{ 'target' => 'Account', 'via' => 'belongs_to' }],
        'UsersController' => [{ 'target' => 'User', 'via' => 'code_reference' }]
      },
      'reverse' => { 'Account' => ['User'], 'User' => ['UsersController'] },
      'pagerank' => { 'User' => 0.5, 'Account' => 0.3, 'UsersController' => 0.1 }
    }
  end

  let(:analysis) do
    { 'hubs' => [{ 'identifier' => 'User', 'type' => 'model', 'dependent_count' => 1 }],
      'cycles' => [], 'orphans' => [], 'bridges' => [] }
  end

  let(:units) do
    {
      'User' => { 'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb',
                  'source_hash' => 'h1',
                  'metadata' => { 'loc' => 10,
                                  'associations' => [{ 'type' => 'belongs_to', 'target' => 'Account' }] } },
      'Account' => { 'identifier' => 'Account', 'type' => 'model', 'file_path' => 'app/models/account.rb',
                     'source_hash' => 'h2', 'metadata' => {} },
      'UsersController' => { 'identifier' => 'UsersController', 'type' => 'controller',
                             'file_path' => 'app/controllers/users_controller.rb', 'metadata' => {} },
      'RailsThing' => { 'identifier' => 'RailsThing', 'type' => 'rails_source', 'metadata' => {} }
    }
  end

  let(:index_entries) { units.keys.map { |id| { 'identifier' => id } } }

  let(:reader) do
    instance_double(Woods::MCP::IndexReader).tap do |r|
      allow(r).to receive(:raw_graph_data).and_return(graph)
      allow(r).to receive(:graph_analysis).and_return(analysis)
      allow(r).to receive(:list_units).and_return(index_entries)
      allow(r).to receive(:find_unit) { |id| units[id] }
    end
  end

  def exporter(**overrides)
    described_class.new(index_dir: 'unused', vault_path: @vault, reader: reader,
                        output: StringIO.new, **overrides)
  end

  def read_vault(rel)
    File.read(File.join(@vault, rel), encoding: 'UTF-8')
  end

  def frontmatter(rel)
    content = read_vault(rel)
    YAML.safe_load(content.split("\n---\n").first)
  end

  describe '#export_all' do
    it 'writes one note per app unit and excludes framework units by default' do
      stats = exporter.export_all
      expect(stats[:exported]).to eq(3)
      expect(File).to exist(File.join(@vault, 'models/User.md'))
      expect(File).to exist(File.join(@vault, 'models/Account.md'))
      expect(File).to exist(File.join(@vault, 'controllers/UsersController.md'))
      expect(Dir.glob(File.join(@vault, '**/RailsThing.md'))).to be_empty
    end

    it 'includes framework units when include_framework is set' do
      exporter(include_framework: true).export_all
      expect(Dir.glob(File.join(@vault, '**/RailsThing.md'))).not_to be_empty
    end

    it 'writes flat, valid YAML frontmatter with persisted pagerank as a number' do
      exporter.export_all
      fm = frontmatter('models/User.md')
      expect(fm).to include('id' => 'User', 'type' => 'model', 'woods_managed' => true)
      expect(fm['pagerank']).to eq(0.5)
      expect(fm['tags']).to include('woods/hub')
    end

    it 'derives edges from the graph: forward as Depends on, reverse as Used by' do
      exporter.export_all
      expect(read_vault('models/User.md')).to include('[[models/Account|Account]] — *belongs_to*')
      expect(read_vault('models/Account.md')).to include('[[models/User|User]]')
      expect(read_vault('models/Account.md')).to match(/## Used by \(1\)/)
    end

    it 'emits no dangling wikilinks (every link target has a note)' do
      exporter.export_all
      Dir.glob(File.join(@vault, '**/*.md')).each do |file|
        File.read(file, encoding: 'UTF-8').scan(/\[\[([^\]|]+)\|/).flatten.each do |target|
          next if target.start_with?('_woods') # n/a

          expect(File).to(exist(File.join(@vault, "#{target}.md")), "dangling link #{target} in #{file}")
        end
      end
    end

    it 'skips a graph node that has no unit file on disk (counts it as skipped, links nowhere)' do
      graph['nodes']['Ghost'] = { 'type' => 'model' }
      allow(reader).to receive(:find_unit) { |id| id == 'Ghost' ? nil : units[id] }
      allow(reader).to receive(:list_units).and_return(index_entries + [{ 'identifier' => 'Ghost' }])

      stats = exporter.export_all
      expect(File).not_to exist(File.join(@vault, 'models/Ghost.md'))
      expect(stats[:skipped]).to be >= 1
      expect(Dir.glob(File.join(@vault, '**/*.md')).map do |f|
        File.read(f, encoding: 'UTF-8')
      end.join).not_to include('Ghost')
    end

    it 'skips a unit whose file is corrupt (find_unit raises) without aborting the export' do
      allow(reader).to receive(:find_unit) do |id|
        raise JSON::ParserError, 'truncated json' if id == 'Account'

        units[id]
      end
      stats = exporter.export_all
      expect(stats[:exported]).to eq(2) # User + UsersController; Account dropped
      expect(stats[:skipped]).to be >= 1
      expect(File).not_to exist(File.join(@vault, 'models/Account.md'))
      expect(read_vault('models/User.md')).not_to include('[[models/Account') # no dangling link
    end

    it 'dedupes duplicate graph edges so a note renders one bullet per target/via' do
      graph['edges']['User'] = [
        { 'target' => 'Account', 'via' => 'belongs_to' },
        { 'target' => 'Account', 'via' => 'belongs_to' }
      ]
      exporter.export_all
      note = read_vault('models/User.md')
      expect(note.scan('[[models/Account|Account]] — *belongs_to*').size).to eq(1)
      expect(frontmatter('models/User.md')['dependency_count']).to eq(1)
    end
  end

  describe 'machine sidecar' do
    it 'writes a manifest with bijective notes/paths maps and verbatim graph copies' do
      exporter.export_all
      manifest = JSON.parse(read_vault('_woods/manifest.json'))
      expect(manifest['notes']['User']).to include('path' => 'models/User.md', 'type' => 'model', 'pagerank' => 0.5)
      expect(manifest['paths']['models/User.md']).to eq('User')
      manifest['notes'].each { |id, info| expect(manifest['paths'][info['path']]).to eq(id) }

      expect(JSON.parse(read_vault('_woods/dependency_graph.json'))).to eq(graph)
      expect(JSON.parse(read_vault('_woods/graph_analysis.json'))).to eq(analysis)
    end

    it 'per-note machine-contract links match the sidecar edges' do
      exporter.export_all
      user = read_vault('models/User.md')
      depends_links = user[/## Depends on.*?(?=\n## |\z)/m].to_s.scan(%r{\[\[models/(\w+)}).flatten
      expect(depends_links).to contain_exactly('Account')
    end
  end

  describe 'MOC + overview' do
    it 'writes a per-type _index and a root _Overview' do
      stats = exporter.export_all
      expect(stats[:indexes]).to be >= 3
      expect(read_vault('models/_index.md')).to include('[[models/User|User]]', '[[models/Account|Account]]')
      expect(read_vault('_Overview.md')).to include('# Woods Vault Overview')
    end
  end

  describe '.obsidian config + Bases' do
    it 'writes config + Units.base + sentinel into a woods-owned vault' do
      exporter.export_all
      expect(JSON.parse(read_vault('.obsidian/app.json'))).to include('newLinkFormat' => 'absolute')
      expect(JSON.parse(read_vault('.obsidian/types.json'))['types']).to include('pagerank' => 'number')
      expect(JSON.parse(read_vault('.obsidian/graph.json'))['colorGroups']).not_to be_empty
      expect { YAML.safe_load(read_vault('Units.base')) }.not_to raise_error
      expect(File).to exist(File.join(@vault, '.woods-vault'))
    end
  end

  describe 'determinism' do
    def snapshot
      Dir.glob(File.join(@vault, '**', '*'), File::FNM_DOTMATCH)
         .select { |f| File.file?(f) }
         .sort
         .to_h { |f| [Pathname(f).relative_path_from(Pathname(@vault)).to_s, File.read(f)] }
    end

    it 'produces byte-identical output across runs' do
      exporter.export_all
      first = snapshot
      exporter.export_all
      expect(snapshot).to eq(first)
    end
  end

  describe 'graceful degradation' do
    it 'still generates notes when graph_analysis.json is absent (reader raises)' do
      allow(reader).to receive(:graph_analysis).and_raise(Errno::ENOENT)
      stats = exporter.export_all
      expect(stats[:exported]).to eq(3)
      expect(File).not_to exist(File.join(@vault, '_woods/graph_analysis.json'))
      expect(read_vault('models/User.md')).not_to include('woods/hub')
    end

    it 'raises a friendly ExportError when the index dir has no manifest' do
      Dir.mktmpdir do |empty|
        expect { described_class.new(index_dir: empty, vault_path: @vault) }
          .to raise_error(Woods::Obsidian::ExportError, /woods:extract/)
      end
    end
  end

  describe 'stale-note sweep' do
    def write_managed_note(rel, marker: true)
      path = File.join(@vault, rel)
      FileUtils.mkdir_p(File.dirname(path))
      fm = marker ? "---\nwoods_managed: true\n---\n" : "---\nfoo: bar\n---\n"
      File.write(path, "#{fm}\n# stale")
    end

    it 'deletes a stale managed note but keeps unmanaged user notes' do
      exporter.export_all # establishes sentinel + the current managed set
      write_managed_note('models/Deleted.md', marker: true)
      write_managed_note('models/MyOwnNote.md', marker: false)

      swept = exporter.export_all[:swept]
      expect(swept).to eq(1)
      expect(File).not_to exist(File.join(@vault, 'models/Deleted.md'))
      expect(File).to exist(File.join(@vault, 'models/MyOwnNote.md'))
    end

    it 'never sweeps a file whose frontmatter fence is non-canonical (conservative — only exact ---\\n notes)' do
      exporter.export_all
      # Contains the marker but closes with "--- " (trailing space), not "---\n".
      # A loose matcher would treat this as ours and DELETE it; we must not.
      foreign = File.join(@vault, 'models/Ambiguous.md')
      File.write(foreign, "---\nwoods_managed: true\n--- \n# not a woods note\n")

      exporter.export_all
      expect(File).to exist(foreign)
    end

    it 'refuses a mass purge above 30% unless force_purge is set' do
      exporter.export_all
      10.times { |i| write_managed_note("models/Stale#{i}.md") }

      expect(exporter.export_all[:swept]).to eq(0) # guard blocks
      expect(exporter(force_purge: true).export_all[:swept]).to be >= 10
    end
  end

  describe 'path traversal safety' do
    it 'sanitizes an unknown node type used as a fallback directory so a note stays inside the vault' do
      graph['nodes']['Evil'] = { 'type' => '../../escape' }
      units['Evil'] = { 'identifier' => 'Evil', 'type' => '../../escape', 'metadata' => {} }
      allow(reader).to receive(:list_units).and_return(index_entries + [{ 'identifier' => 'Evil' }])

      exporter.export_all

      parent = File.dirname(@vault)
      expect(Dir.glob(File.join(parent, '*')).map { |f| File.basename(f) }).to eq(['vault'])
      escaped = Dir.glob(File.join(parent, '**', 'Evil.md')).reject { |f| f.start_with?(@vault) }
      expect(escaped).to be_empty

      note_path = Dir.glob(File.join(@vault, '**', 'Evil.md')).first
      expect(note_path).not_to be_nil
      dir_component = Pathname.new(note_path).relative_path_from(Pathname.new(@vault)).dirname.to_s
      expect(dir_component).not_to include('..')
      expect(dir_component).not_to include('/')
    end

    it 'refuses (via the write guard) to write a path that resolves outside the vault root' do
      exp = exporter
      outside = Pathname.new(File.join(File.dirname(@vault), 'escaped.md'))

      expect { exp.send(:safe_write, outside, 'evil') }
        .to raise_error(Woods::Obsidian::PathTraversalError)
      expect(File).not_to exist(outside)
    end

    it 'allows the write guard to write a path that resolves inside the vault root' do
      exp = exporter
      inside = exp.instance_variable_get(:@vault).join('ok.md')

      expect { exp.send(:safe_write, inside, 'fine') }.not_to raise_error
      expect(File.read(inside)).to eq('fine')
    end
  end

  describe 'foreign-vault safety' do
    it 'writes notes additively but skips config and sweep when the vault is foreign' do
      FileUtils.mkdir_p(@vault)
      File.write(File.join(@vault, 'my-existing-note.md'), '# mine')

      stats = exporter.export_all
      expect(stats[:exported]).to eq(3) # notes still written
      expect(File).to exist(File.join(@vault, 'my-existing-note.md')) # untouched
      expect(File).not_to exist(File.join(@vault, '.obsidian/app.json'))
      expect(File).not_to exist(File.join(@vault, '.woods-vault'))
      expect(stats[:swept]).to eq(0)
    end
  end
end
