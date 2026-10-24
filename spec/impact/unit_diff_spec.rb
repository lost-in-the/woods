# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'woods/impact/unit_diff'

RSpec.describe Woods::Impact::UnitDiff do
  around do |example|
    Dir.mktmpdir('woods-unit-diff') do |dir|
      @root = dir
      example.run
    end
  end

  def publish(number, units)
    payload = File.join(@root, 'payloads', "gen-#{number}")
    units.group_by { |data| Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR.fetch(data['type']) }.each do |dir, records|
      write_units(File.join(payload, dir), records)
    end
    FileUtils.mkdir_p(payload)
    File.write(File.join(payload, 'manifest.json'), JSON.generate('git_sha' => 'a' * 40, 'total_units' => units.size))
    File.write(File.join(@root, 'generation.json'),
               JSON.generate('number' => number, 'token' => "t#{number}", 'payload' => "payloads/gen-#{number}"))
  end

  def write_units(dir, records)
    FileUtils.mkdir_p(dir)
    records.each do |data|
      id = data.fetch('identifier')
      File.write(File.join(dir, "#{id}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json"), JSON.generate(data))
    end
    File.write(File.join(dir, '_index.json'), JSON.generate(records.map { |data| data.slice('identifier') }))
  end

  def unit(identifier, source)
    { 'identifier' => identifier, 'type' => 'model', 'source_code' => source, 'metadata' => {}, 'dependencies' => [] }
  end

  let(:post) { { 'identifier' => 'Post', 'type' => 'model' } }

  before do
    publish(1, [unit('Post', "class Post\n  def a; end\nend\n"), unit('Gone', "x\n")])
    publish(2, [unit('Post', "class Post\n  def a; 1; end\nend\n"), unit('New', "y\n")])
  end

  it 'gives one unit\'s unified diff with both endpoints\' line numbers and their provenance' do
    diff = described_class.compare(@root, unit: post, from: 'gen:1', context: 1)

    expect(diff).to include('schema_version' => 1, 'identifier' => 'Post', 'type' => 'model', 'status' => 'modified')
    expect(diff.dig('range', 'from', 'generation')).to eq(1)
    expect(diff.dig('range', 'to', 'generation')).to eq(2)
    expect(diff['source_changes']['hunks'].first['lines'].map { |line| line.values_at('op', 'before', 'after') })
      .to eq([[' ', 1, 1], ['-', 2, nil], ['+', nil, 2], [' ', 3, 3]])
  end

  it 'names the facets and categories that moved, as the range report records them' do
    publish(3, [unit('Post', "class Post\n  def a; 1; end\nend\n").merge('metadata' => { 'callbacks' => [1] })])
    diff = described_class.compare(@root, unit: post, from: 'gen:2', to: 'gen:3')

    expect(diff).to include('status' => 'modified', 'facets' => ['metadata'], 'categories' => ['behaviour'],
                            'metadata_keys' => ['callbacks'])
    expect(diff['source_changes']).to include('hunks' => [], 'coverage' => 'complete')
    expect(described_class.compare(@root, unit: post, from: 'gen:1', to: 'gen:2'))
      .to include('facets' => ['source'], 'categories' => ['behaviour'])
  end

  it 'names the columns that moved, as the report records them (#821)' do
    columns = ->(*names) { names.map { |name| { 'name' => name, 'type' => 'string' } } }
    publish(3,
            [unit('Post',
                  "class Post\n  def a; 1; end\nend\n").merge('metadata' => { 'columns' => columns.call('id') })])
    publish(4, [unit('Post', "class Post\n  def a; 1; end\nend\n")
      .merge('metadata' => { 'columns' => columns.call('id', 'slug') })])

    expect(described_class.compare(@root, unit: post, from: 'gen:3', to: 'gen:4')['column_changes'])
      .to eq('added' => ['slug'], 'removed' => [], 'modified' => [])
  end

  it 'names an added, removed, absent or unchanged unit without a diff to draw' do
    statuses = %w[New Gone Nope].map do |identifier|
      described_class.compare(@root, unit: { 'identifier' => identifier, 'type' => 'model' }, from: 'gen:1')['status']
    end
    expect(statuses).to eq(%w[added removed absent])
    expect(described_class.compare(@root, unit: post, from: 'gen:2'))
      .to include('status' => 'unchanged', 'facets' => [], 'categories' => [])
  end

  it 'is frozen and refuses an unbounded context' do
    expect(described_class.compare(@root, unit: post, from: 'gen:1')).to be_frozen
    expect { described_class.compare(@root, unit: post, from: 'gen:1', context: 99) }
      .to raise_error(ArgumentError, /context/)
  end
end
