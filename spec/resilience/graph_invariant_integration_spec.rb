# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/filename_utils'
require 'woods/resilience/index_validator'

RSpec.describe 'Published index semantic graph validation' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-graph-validation') }
  let(:graph) do
    {
      'nodes' => { 'A' => { 'type' => 'model', 'file_path' => 'app/models/a.rb' } },
      'edges' => { 'A' => [{ 'target' => 'http_api', 'via' => 'code_reference' }] },
      'reverse' => { 'http_api' => ['A'] },
      'file_map' => { 'app/models/a.rb' => ['A'] }, 'type_index' => { 'model' => ['A'] }
    }
  end

  before do
    model_dir = File.join(index_dir, 'models')
    FileUtils.mkdir_p(model_dir)
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate(counts: { models: 1 }))
    File.write(File.join(model_dir, '_index.json'), JSON.generate([{ identifier: 'A', file_path: 'app/models/a.rb' }]))
    File.write(File.join(model_dir, collision_safe_filename('A')),
               JSON.generate(identifier: 'A', type: 'model', file_path: 'app/models/a.rb', source_code: 'class A; end'))
    write_graph
  end

  after { FileUtils.remove_entry(index_dir) }

  def write_graph
    File.write(File.join(index_dir, 'dependency_graph.json'), JSON.generate(graph))
  end

  it 'rejects a parseable graph that lost the reverse entry for an external target' do
    validator = Woods::Resilience::IndexValidator.new(index_dir: index_dir)
    expect(validator.validate.valid?).to be(true)
    graph['reverse'].clear
    write_graph

    report = validator.validate

    expect(report.valid?).to be(false)
    expect(report.errors).to include('dependency_graph.json reverse["http_api"]: missing "A"')
  end

  it 'rejects a graph that lost an indexed typed node even when all artifacts parse' do
    graph['nodes'].clear
    graph['edges'].clear
    graph['reverse'].clear
    graph['file_map'].clear
    graph['type_index'].clear
    write_graph

    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate

    expect(report.valid?).to be(false)
    expect(report.errors).to include('dependency_graph.json nodes: missing indexed unit model:A')
  end
  def publish_generation(number)
    relative = "payloads/gen-#{number}"
    target = File.join(index_dir, relative)
    FileUtils.mkdir_p(target)
    %w[models manifest.json dependency_graph.json].each do |name|
      FileUtils.cp_r(File.join(index_dir, name), target)
    end
    Woods::Generation.new(output_dir: index_dir).bump!(payload: relative)
    target
  end

  it 'pins all checks while publication advances and retention tries to remove the old payload' do
    first = publish_generation(1)
    validator = Woods::Resilience::IndexValidator.new(index_dir: index_dir)
    allow(validator).to receive(:validate_flow_artifacts).and_wrap_original do |method, errors|
      graph['reverse'].clear
      write_graph
      publish_generation(2)
      removed = Woods::PayloadStore.new(index_dir).prune(keep: 1, protect: 2)
      expect(removed).to be_empty
      expect(File.directory?(first)).to be(true)
      method.call(errors)
    end

    expect(validator.validate.valid?).to be(true)
    expect(Woods::PayloadStore.new(index_dir).prune(keep: 1, protect: 2)).to eq([1])
    current = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate
    expect(current.errors).to include('dependency_graph.json reverse["http_api"]: missing "A"')
  end

  it 'releases the retention pin when an artifact read fails' do
    first = publish_generation(1)
    validator = Woods::Resilience::IndexValidator.new(index_dir: index_dir)
    allow(validator).to receive(:validate_dependency_graph).and_raise(IOError, 'injected read failure')

    report = validator.validate
    expect(report.valid?).to be(false)
    expect(report.errors.join).to include('injected read failure')
    publish_generation(2)
    expect(Woods::PayloadStore.new(index_dir).prune(keep: 1, protect: 2)).to eq([1])
    expect(File.directory?(first)).to be(false)
  end

  it 'rejects a corrupt generation pointer instead of validating the older flat-root artifacts' do
    File.write(File.join(index_dir, 'generation.json'), '{broken')

    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate

    expect(report.valid?).to be(false)
    expect(report.errors.join).to include('Unreadable generation pointer')
  end

  it 'validates the real unit identity rather than trusting its filename and directory' do
    file = File.join(index_dir, 'models', collision_safe_filename('A'))
    data = JSON.parse(File.read(file)).merge('identifier' => 'Different', 'type' => 'service')
    File.write(file, JSON.generate(data))

    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate

    expect(report.errors).to include("#{file}: expected typed unit model:A")
  end

  it 'compares graph paths against unit artifacts when legacy index summaries omit the path' do
    File.write(File.join(index_dir, 'models', '_index.json'), JSON.generate([{ identifier: 'A' }]))
    file = File.join(index_dir, 'models', collision_safe_filename('A'))
    File.write(file, JSON.generate(JSON.parse(File.read(file)).merge('file_path' => 'app/models/elsewhere.rb')))

    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate

    expect(report.errors).to include('dependency_graph.json unit indexes: file_path differs for model:A')
  end

  it 'uses the actual gem_source identity in the shared rails_source directory' do
    FileUtils.mv(File.join(index_dir, 'models'), File.join(index_dir, 'rails_source'))
    file = File.join(index_dir, 'rails_source', collision_safe_filename('A'))
    File.write(file, JSON.generate(JSON.parse(File.read(file)).merge('type' => 'gem_source')))
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate(counts: { rails_source: 1 }))
    graph['nodes']['A']['type'] = 'gem_source'
    graph['type_index'] = { 'gem_source' => ['A'] }
    write_graph

    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate

    expect(report.errors).to be_empty
  end

  it 'validates a real disposable Woods static source map with its own type families' do
    require 'woods/gem_mapper'
    source = Dir.mktmpdir('woods-map-source')
    target = Dir.mktmpdir('woods-map-validation')
    FileUtils.mkdir_p(File.join(source, 'lib'))
    File.write(File.join(source, 'lib', 'woods.rb'), "module Woods; class Example; def call; end; end; end\n")
    Woods::GemMapper.new(root: source, output_dir: target).map!

    report = Woods::Resilience::IndexValidator.new(index_dir: target).validate

    expect(report.errors).to be_empty
  ensure
    FileUtils.remove_entry(source) if source
    FileUtils.remove_entry(target) if target
  end
end
