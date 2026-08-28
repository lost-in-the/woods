# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/gem_mapper'
require 'woods/mcp/index_reader'

RSpec.describe Woods::GemMapper do
  let(:root) { File.expand_path('..', __dir__) }
  let(:output_dir) { Dir.mktmpdir('woods_self_map') }

  after { FileUtils.rm_rf(output_dir) }

  def payload_dir
    Woods::Generation.new(output_dir: output_dir).payload_dir
  end

  it 'publishes a complete, MCP-readable static source generation' do
    result = described_class.new(root: root, output_dir: output_dir).map!

    expect(result).to include(status: :published, generation: 1)
    expect(payload_dir.join('manifest.json')).to be_file
    expect(payload_dir.join('ruby_classes', '_index.json')).to be_file
    expect(payload_dir.join('ruby_modules', '_index.json')).to be_file
    expect(payload_dir.join('ruby_methods', '_index.json')).to be_file
    expect(payload_dir.join('ruby_files', '_index.json')).to be_file

    reader = Woods::MCP::IndexReader.new(output_dir)
    expect(reader.manifest.dig('provenance', 'mode')).to eq('woods_static_ruby_source')
    expect(reader.find_unit('Woods::Extractor')).to include('file_path' => 'lib/woods/extractor.rb')
    expect(reader.find_unit('Woods::RubyAnalyzer')).not_to be_nil
    expect(reader.find_unit('Woods::MCP::IndexReader')).not_to be_nil
    expect(reader.search('Woods::Extractor', types: ['ruby_class'])[:results].map { |entry| entry[:identifier] })
      .to include('Woods::Extractor')
    expect(reader.traverse_dependencies('Woods::MCP::IndexReader')[:found]).to be(true)
  end

  it 'preserves source-map types for MCP filtering' do
    described_class.new(root: root, output_dir: output_dir).map!

    unit = Woods::MCP::IndexReader.new(output_dir).find_unit('Woods::RubyAnalyzer')
    expect(unit).to include('type' => 'ruby_module')
    expect(reader = Woods::MCP::IndexReader.new(output_dir)).to be_a(Woods::MCP::IndexReader)
    expect(reader.search('Woods::RubyAnalyzer', types: ['ruby_module'])[:results])
      .to include(hash_including(identifier: 'Woods::RubyAnalyzer', type: 'ruby_module'))
  end

  it 'skips an unchanged tree without advancing the generation' do
    mapper = described_class.new(root: root, output_dir: output_dir)
    mapper.map!

    expect(mapper.map!).to include(status: :skipped, generation: 1)
  end

  it 'writes only repository-relative source paths' do
    described_class.new(root: root, output_dir: output_dir).map!

    entries = Dir[payload_dir.join('ruby_*', '_index.json').to_s].flat_map { |path| JSON.parse(File.read(path)) }
    expect(entries.map { |entry| entry['file_path'] }).to all(satisfy { |path| !path.start_with?('/') })
    expect(entries.map { |entry| entry['file_path'] }).to include('lib/tasks/woods.rake', 'exe/woods-mcp')
  end
end
