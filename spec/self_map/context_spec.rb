# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/self_map/task'

RSpec.describe Woods::SelfMap::Task do
  around do |example|
    Dir.mktmpdir('woods-context') do |directory|
      @root = Pathname.new(directory)
      @index = @root.join('tmp/index')
      @output = @root.join('tmp/context')
      example.run
    end
  end

  def write(path, source)
    destination = @root.join(path)
    FileUtils.mkdir_p(destination.dirname)
    File.write(destination, source)
  end

  def task
    described_class.new(root: @root, index_dir: @index, output_dir: @output)
  end

  before do
    write('lib/woods/store.rb', 'module Example; class Store; end; end')
    write('lib/woods/runner.rb', 'module Example; class Runner; def run; Store.new; end; end; end')
    write('spec/support/store.rb', 'Example::Store.new')
    write('spec/helper_spec.rb', "require_relative 'support/store'")
    write('spec/runner_spec.rb', 'RSpec.describe Example::Runner do; end')
  end

  it 'suggests helper consumers and labels the inferred owner path' do
    result = task.impact(paths: ['lib/woods/store.rb'])
    report = JSON.parse(File.read(File.join(result, 'impact.json')))
    expect(report['suggested_specs']).to include('spec/helper_spec.rb', 'spec/runner_spec.rb')
    runner = report['endpoints'].first['affected'].find { |item| item['identifier'] == 'file:spec/runner_spec.rb' }
    expect(runner['paths'].flat_map { |path| path['edges'].map { |edge| edge['via'] } }).to include('owner_expansion')
    expect(report.dig('coverage', 'complete')).to be(false)
    expect(report.dig('coverage', 'baseline')).to eq('unavailable')
  end

  it 'uses an explicit old generation for deletions and refuses missing baselines' do
    task.docs
    File.delete(@root.join('lib/woods/store.rb'))
    result = task.impact(paths: ['lib/woods/store.rb'], base_generation: 1)
    report = JSON.parse(File.read(File.join(result, 'impact.json')))
    expect(report['endpoints'].last['seeds']).not_to be_empty
    expect(report['suggested_specs']).to include('spec/helper_spec.rb')
    expect(report.dig('coverage', 'baseline')).to eq('selected_snapshot_not_git_verified')
    previous = File.read(@output.join('latest-impact.json'))
    expect { task.impact(paths: ['lib/woods/store.rb'], base_generation: 999) }.to raise_error(IOError)
    expect(File.read(@output.join('latest-impact.json'))).to eq(previous)
  end

  it 'does not imply no impact for paths outside the map or failed parses' do
    write('lib/woods/broken.rb', 'class Broken; def run(')
    result = task.impact(paths: ['lib/woods/broken.rb', 'Gemfile'])
    report = JSON.parse(File.read(File.join(result, 'impact.json')))
    expect(report['endpoints'].first['unmapped_paths']).to include('Gemfile')
    expect(report['endpoints'].first['parse_failures']).to include(include('path' => 'lib/woods/broken.rb'))
    expect(File.read(File.join(result, 'impact.md'))).to include('not exhaustive', 'CONTRIBUTING.md')
  end

  it 'publishes a reusable bounded guide with provenance and a complete inventory' do
    result = task.docs
    expect(task.docs).to eq(result)
    pointer = JSON.parse(File.read(@output.join('current.json')))
    expect(@output.join(pointer['path']).to_s).to eq(result)
    manifest = JSON.parse(File.read(File.join(result, 'manifest.json')))
    expect(manifest['freshness']).to eq('matched_before_publication')
    expect(manifest['source_checksum']).to match(/\A[0-9a-f]{64}\z/)
    expect(File.read(File.join(result, 'START_HERE.md'))).to include('static', 'reference_only')
    inventory = JSON.parse(File.read(File.join(result, 'inventory.json')))
    expect(inventory['units']).to include(include('identifier' => 'Example::Runner#run'))
  end

  it 'leaves the prior guide pointer intact if source changes during rendering' do
    task.docs
    previous = File.read(@output.join('current.json'))
    allow_any_instance_of(Woods::SelfMap::Guide).to receive(:files).and_wrap_original do |method|
      files = method.call
      write('lib/woods/new.rb', 'class New; end')
      files
    end
    expect { task.docs }.to raise_error(IOError, /changed/)
    expect(File.read(@output.join('current.json'))).to eq(previous)
  end

  it 'pins the selected baseline before refresh can prune it' do
    task.docs
    2.times do |number|
      write('lib/woods/new.rb', "class New#{number}; end")
      task.docs
    end
    File.delete(@root.join('lib/woods/store.rb'))
    result = task.impact(paths: ['lib/woods/store.rb'], base_generation: 1)
    report = JSON.parse(File.read(File.join(result, 'impact.json')))
    expect(report['suggested_specs']).to include('spec/helper_spec.rb')
  end

  it 'preserves explicit budget notices and never asserts an exhaustive result' do
    result = task.impact(paths: ['lib/woods/store.rb'], options: { max_nodes: 1 })
    report = JSON.parse(File.read(File.join(result, 'impact.json')))
    expect(report['endpoints'].first['traversal']).to eq('partial')
    expect(report['endpoints'].first['unknowns']).to include(include('kind' => 'node_budget'))
    expect(report.dig('coverage', 'complete')).to be(false)
  end

  it 'inventories nonignored unsupported inputs and bounds completed view retention' do
    system('git', '-C', @root.to_s, 'init', '--quiet', exception: true)
    write('.gitignore', "tmp/\n")
    write('script/check.sh', '#!/bin/sh')
    result = task.docs
    inventory = JSON.parse(File.read(File.join(result, 'inventory.json')))
    expect(inventory.dig('inputs', 'scope')).to eq('git_nonignored')
    expect(inventory.dig('inputs', 'files')).to include(include('path' => 'script/check.sh', 'mode' => 'not_mapped'))
    4.times do |number|
      write('lib/woods/new.rb', "class New#{number}; end")
      task.docs
    end
    expect(@output.join('views').children.size).to eq(3)
  end

  it 'refuses invalid source encoding without replacing the completed guide' do
    task.docs
    previous = File.read(@output.join('current.json'))
    File.binwrite(@root.join('lib/woods/store.rb'), "class Store; end\xff".b)
    expect { task.docs }.to raise_error(Woods::ExtractionError, /Invalid UTF-8/)
    expect(File.read(@output.join('current.json'))).to eq(previous)
  end

  it 'rejects escaping paths and invalid budgets before publishing impact' do
    expect { task.impact(paths: ['../outside.rb']) }.to raise_error(ArgumentError)
    expect { task.impact(paths: ['lib/woods/store.rb'], options: { max_nodes: 0 }) }.to raise_error(ArgumentError)
    expect(@output.join('latest-impact.json')).not_to exist
  end
end
