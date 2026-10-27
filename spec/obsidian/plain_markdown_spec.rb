# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'yaml'
require 'stringio'
require 'woods/obsidian/vault_exporter'
require 'woods/mcp/index_reader'

RSpec.describe 'plain Markdown export (obsidian: false)' do
  around do |example|
    Dir.mktmpdir do |dir|
      @vault = File.join(dir, 'out')
      example.run
    end
  end

  let(:mapper) do
    Woods::Obsidian::NameMapper.new('User' => 'models', 'Account' => 'models', 'UsersController' => 'controllers')
  end

  describe Woods::Obsidian::NameMapper do
    it 'builds a relative Markdown link across folders' do
      expect(mapper.markdown_link('User', from: 'controllers/UsersController.md')).to eq('[User](../models/User.md)')
    end

    it 'builds a same-folder link without a leading dot segment' do
      expect(mapper.markdown_link('Account', from: 'models/User.md')).to eq('[Account](Account.md)')
    end

    it 'returns nil for an unknown id' do
      expect(mapper.markdown_link('Nope', from: 'models/User.md')).to be_nil
    end
  end

  describe Woods::Obsidian::NoteBuilder do
    let(:nodes) do
      { 'User' => { 'type' => 'model' }, 'Account' => { 'type' => 'model' },
        'UsersController' => { 'type' => 'controller' } }
    end
    let(:analysis) { { 'hubs' => [{ 'identifier' => 'User' }], 'cycles' => [], 'orphans' => [], 'bridges' => [] } }
    let(:builder) do
      described_class.new(name_mapper: mapper, nodes: nodes, analysis: analysis, obsidian: false)
    end
    let(:note) do
      unit = { 'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb' }
      builder.build(id: 'User', unit: unit,
                    depends_on: [{ target: 'Account', via: 'belongs_to' }], used_by: ['UsersController'])
    end
    let(:frontmatter) { YAML.safe_load(note.split("\n---\n").first) }

    it 'renders no wiki links' do
      expect(note).not_to include('[[')
    end

    it 'links with relative Markdown links' do
      expect(note).to include('- [Account](Account.md)')
      expect(note).to include('[UsersController](../controllers/UsersController.md)')
    end

    it 'drops the Obsidian tags and aliases but keeps the managed marker and facts' do
      expect(frontmatter).not_to have_key('tags')
      expect(frontmatter).not_to have_key('aliases')
      expect(frontmatter).to include('woods_managed' => true, 'id' => 'User', 'type' => 'model')
    end

    it 'renders hub callouts without Obsidian callout syntax' do
      expect(note).not_to include('[!warning]')
      expect(note).to include('Hub')
    end
  end

  describe Woods::Obsidian::VaultExporter do
    let(:graph) do
      { 'nodes' => { 'User' => { 'type' => 'model' }, 'Account' => { 'type' => 'model' } },
        'edges' => { 'User' => [{ 'target' => 'Account', 'via' => 'belongs_to' }] },
        'reverse' => { 'Account' => ['User'] }, 'pagerank' => { 'User' => 0.5 } }
    end
    let(:units) do
      { 'User' => { 'identifier' => 'User', 'type' => 'model', 'metadata' => {} },
        'Account' => { 'identifier' => 'Account', 'type' => 'model', 'metadata' => {} } }
    end
    let(:reader) do
      instance_double(Woods::MCP::IndexReader).tap do |r|
        allow(r).to receive(:raw_graph_data).and_return(graph)
        allow(r).to receive(:graph_analysis).and_return(nil)
        allow(r).to receive(:list_units).and_return(units.keys.map { |id| { 'identifier' => id } })
        allow(r).to receive(:find_unit) { |id| units[id] }
      end
    end

    def export(**options)
      described_class.new(index_dir: 'unused', vault_path: @vault, reader: reader, output: StringIO.new,
                          **options).export_all
    end

    def markdown_files
      Dir.glob(File.join(@vault, '**', '*.md'))
    end

    it 'writes only plain Markdown and the machine sidecar' do
      export(obsidian: false)
      expect(File).not_to exist(File.join(@vault, '.obsidian'))
      expect(File).not_to exist(File.join(@vault, 'Units.base'))
      expect(markdown_files.map { |f| File.read(f) }.join).not_to include('[[')
      expect(File).to exist(File.join(@vault, '_woods/manifest.json'))
      expect(File).to exist(File.join(@vault, '.woods-vault'))
    end

    it 'writes links that resolve to files in the export' do
      export(obsidian: false)
      markdown_files.each do |file|
        File.read(file).scan(/\]\(([^)]+\.md)\)/).flatten.each do |href|
          expect(File).to exist(File.expand_path(href, File.dirname(file))), "#{file} links to missing #{href}"
        end
      end
    end

    it 'sweeps stale managed notes in the plain flavor' do
      export(obsidian: false)
      stale = File.join(@vault, 'models/Stale.md')
      File.write(stale, "---\nwoods_managed: true\n---\n# Stale\n")
      export(obsidian: false)
      expect(File).not_to exist(stale)
    end

    it 'keeps the Obsidian flavor when obsidian: true' do
      export(obsidian: true)
      expect(File).to exist(File.join(@vault, '.obsidian/app.json'))
      expect(File.read(File.join(@vault, 'models/User.md'))).to include('[[models/Account|Account]]')
    end

    it 'defaults to the Obsidian flavor for existing direct callers' do
      export
      expect(File).to exist(File.join(@vault, 'Units.base'))
    end
  end
end
