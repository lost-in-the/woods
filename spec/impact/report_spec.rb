# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/impact/report'

RSpec.describe Woods::Impact::Report do
  around do |example|
    Dir.mktmpdir('woods-impact-contract') do |dir|
      @root = dir
      example.run
    end
  end

  def unit(identifier, type, source = 'original', metadata = {})
    { 'identifier' => identifier, 'type' => type, 'source_code' => source,
      'metadata' => metadata, 'dependencies' => [] }
  end

  def publish(number, units, sha: 'a' * 40)
    payload = File.join(@root, 'payloads', "gen-#{number}")
    counts = units.group_by { |data| Woods::MCP::IndexReader::UNIT_TYPE_TO_DIR.fetch(data['type']) }
    counts.each do |dir, records|
      write_units(payload, dir, records)
    end
    FileUtils.mkdir_p(payload)
    File.write(File.join(payload, 'manifest.json'), JSON.generate('git_sha' => sha, 'total_units' => units.size,
                                                                  'counts' => counts.transform_values(&:size)))
    File.write(File.join(@root, 'generation.json'), JSON.generate('number' => number, 'token' => "token-#{number}",
                                                                  'payload' => "payloads/gen-#{number}"))
    payload
  end

  def write_units(payload, dir, records)
    FileUtils.mkdir_p(File.join(payload, dir))
    records.each do |data|
      id = data.fetch('identifier')
      filename = "#{id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}_#{Digest::SHA256.hexdigest(id)[0, 8]}.json"
      File.write(File.join(payload, dir, filename), JSON.generate(data))
    end
    File.write(File.join(payload, dir, '_index.json'), JSON.generate(records.map { |data| data.slice('identifier') }))
  end

  def report(from: 'gen:1', to: 'now')
    described_class.compare(@root, from: from, to: to)
  end

  def write_graph(payload, target, via, weight)
    edge = { 'source' => 'Caller', 'source_type' => 'service', 'via' => via }
    data = { 'reverse_via' => { target => [edge] }, 'pagerank' => { 'Caller' => weight } }
    File.write(File.join(payload, 'dependency_graph.json'), JSON.generate(data))
  end

  it 'compares actual typed identities, including collisions and shared-directory subtypes' do
    publish(1, [unit('Shared', 'model'), unit('Shared', 'service'), unit('Query', 'graphql_query')])
    publish(2, [unit('Shared', 'model', 'updated'), unit('Shared', 'service'), unit('Query', 'graphql_type')])

    changes = report.to_h.fetch('changed')
    expect(changes.map { |change| change.values_at('identifier', 'type', 'status') }).to eq(
      [%w[Query graphql_query removed], %w[Query graphql_type added], %w[Shared model modified]]
    )
    expect(changes.last).to include('facets' => ['source'], 'categories' => ['behaviour'])
  end

  it 'records where a modified unit\'s source moved, in each endpoint\'s lines (#802)' do
    publish(1, [unit('Example', 'model', "class Example\n  def a; end\nend\n"), unit('Other', 'model')])
    publish(2, [unit('Example', 'model', "class Example\n  def a; end\n  def b; end\nend\n"),
                unit('Other', 'model', 'original', { 'columns' => [] })])

    changes = report.to_h.fetch('changed').to_h { |change| [change['identifier'], change] }
    expect(changes['Example']['source_changes']).to eq(
      'hunks' => [{ 'before' => [2, 0], 'after' => [3, 1] }], 'added_lines' => 1, 'removed_lines' => 0,
      'coverage' => 'complete'
    )
    expect(changes['Other']).not_to have_key('source_changes')
  end

  it 'spends one changed-range budget across the report' do
    publish(1, [unit('A', 'model', "1\n2\n3\n"), unit('B', 'model', "1\n2\n3\n")])
    publish(2, [unit('A', 'model', "x\n2\ny\n"), unit('B', 'model', "x\n2\ny\n")])

    changes = described_class.compare(@root, from: 'gen:1', max_source_hunks: 3).to_h.fetch('changed')
    expect(changes.map do |change|
      change['source_changes'].values_at('coverage') + [change['source_changes']['hunks'].size]
    end)
      .to eq([['complete', 2], ['truncated', 1]])
  end

  it 'matches the synthetic typed range fixture without normalizing public type strings' do
    fixture = JSON.parse(File.read(File.expand_path('../fixtures/impact/typed_range.json', __dir__)))
    publish(1, fixture.fetch('before'))
    publish(2, fixture.fetch('after'))
    actual = report.to_h.fetch('changed').map do |change|
      change.slice('identifier', 'type', 'status', 'facets', 'categories')
    end
    expect(actual).to eq(fixture.fetch('expected'))
  end

  it 'compares retained payloads without temporal snapshots, preserving same-SHA changes' do
    publish(1, [unit('Example', 'model')])
    publish(2, [unit('Example', 'model', 'changed')])

    data = report.to_h
    expect(data.dig('range', 'from')).to include('generation' => 1, 'git_sha' => 'a' * 40)
    expect(data.dig('range', 'from', 'manifest_checksum')).to match(/\A[0-9a-f]{64}\z/)
    expect(data.dig('range', 'from')).not_to have_key('token')
    expect(data['changed'].size).to eq(1)
    expect(data.dig('coverage', 'complete')).to be(false)
    expect(data.dig('coverage', 'affected')).to eq('partial')
    expect(data['unknowns']).not_to be_empty
  end

  it 'names the manifest-only checksum accurately when different payloads share identical manifests' do
    publish(1, [unit('Example', 'model', 'before')])
    publish(2, [unit('Example', 'model', 'after')])
    data = report.to_h
    before = data.dig('range', 'from')
    after = data.dig('range', 'to')
    expect(before.fetch('manifest_checksum')).to eq(after.fetch('manifest_checksum'))
    expect(before).not_to have_key('payload_checksum')
    expect(data.fetch('changed')).to include(include('identifier' => 'Example', 'facets' => ['source']))
  end

  it 'resolves a commit captured by several generations: from its first capture, to its last' do
    publish(1, [], sha: 'b' * 40)
    publish(2, [], sha: 'a' * 40)
    publish(3, [], sha: 'a' * 40)
    publish(4, [], sha: 'a' * 40)
    range = report(from: 'aaaaaaa', to: 'aaaaaaa').to_h['range']
    expect([range.dig('from', 'generation'), range.dig('to', 'generation')]).to eq([2, 4])
    expect(report(from: 'a' * 40).to_h.dig('range', 'from', 'generation')).to eq(2)
  end

  it 'answers a range whose endpoints are one payload without reading its units' do
    publish(1, [unit('Example', 'model')])
    allow(Woods::Impact::RangeDiff).to receive(:new).and_call_original
    data = report(from: 'gen:1', to: 'now').to_h
    expect(Woods::Impact::RangeDiff).not_to have_received(:new)
    expect(data.dig('range', 'from', 'generation')).to eq(1)
    expect(data.dig('range', 'to', 'generation')).to eq(1)
    expect(data.values_at('changed', 'affected', 'flows')).to all(eq([]))
  end

  it 'rejects a SHA prefix that matches different commits, with generation alternatives' do
    publish(1, [], sha: "abcdef0#{'1' * 33}")
    publish(2, [], sha: "abcdef0#{'2' * 33}")
    expect { report(from: 'abcdef0') }.to raise_error(Woods::Impact::ResolutionError, /gen:1.*gen:2/)
  end

  it 'resolves unique SHA prefixes and integer generations' do
    publish(1, [], sha: 'b' * 40)
    publish(2, [], sha: 'c' * 40)
    expect(report(from: 'bbbbbbb', to: 2).to_h.dig('range', 'from', 'generation')).to eq(1)
  end

  it 'rejects missing generations and unknown SHAs instead of producing an empty diff' do
    publish(2, [])
    expect { report }.to raise_error(Woods::Impact::ResolutionError, /gen:2/)
    expect { report(from: 'ddddddd') }.to raise_error(Woods::Impact::ResolutionError, /gen:2/)
  end

  it 'holds both selected readers through comparison and releases locks afterwards' do
    publish(1, [unit('Example', 'model')])
    publish(2, [])
    allow(Woods::Impact::RangeDiff).to receive(:new).and_wrap_original do |original, *args, **options|
      expect(Woods::PayloadStore.new(@root).prune(keep: 1, protect: 2)).to eq([])
      original.call(*args, **options)
    end
    report
    expect(Woods::PayloadStore.new(@root).prune(keep: 1, protect: 2)).to eq([1])
  end

  it 'fails closed on a missing indexed unit and releases locks on failure' do
    payload = publish(1, [unit('Example', 'model')])
    publish(2, [])
    FileUtils.rm(Dir[File.join(payload, 'models', 'Example_*.json')].first)
    expect { report }.to raise_error(SystemCallError)
    expect(Woods::PayloadStore.new(@root).prune(keep: 1, protect: 2)).to eq([1])
  end

  it 'rejects missing type indexes' do
    payload = publish(1, [unit('Example', 'model')])
    publish(2, [])
    FileUtils.rm(File.join(payload, 'models', '_index.json'))
    expect { report }.to raise_error(IOError, /missing unit index/)
  end

  it 'rejects malformed payload fields, corrupt manifests and invalid total counts' do
    publish(1, [unit('Example', 'model').merge('metadata' => [])])
    payload = publish(2, [])
    expect { report }.to raise_error(IOError, /requires source_code, metadata and dependencies/)
    File.write(File.join(payload, 'manifest.json'), '{ corrupt')
    expect { report(from: 'gen:2') }.to raise_error(JSON::ParserError)
    File.write(File.join(payload, 'manifest.json'), JSON.generate('counts' => {}, 'total_units' => 1))
    expect { report(from: 'gen:2') }.to raise_error(IOError, /counts and total_units/)
  end

  it 'does not adopt a newer now endpoint during computation' do
    publish(1, [])
    publish(2, [])
    allow(Woods::Impact::RangeDiff).to receive(:new).and_wrap_original do |original, *args, **options|
      publish(3, [unit('Later', 'model')])
      original.call(*args, **options)
    end
    expect(report.to_h.dig('range', 'to', 'generation')).to eq(2)
  end

  it 'compares metadata key order canonically and preserves added null facts as unknown' do
    publish(1, [unit('Example', 'model', 'same', { 'a' => 1, 'b' => 2 })])
    publish(2, [unit('Example', 'model', 'same', { 'b' => 2, 'a' => 1 })])
    expect(report.to_h['changed']).to eq([])
    publish(3, [unit('Example', 'model', 'same', { 'b' => 2, 'a' => 1, 'custom_fact' => nil })])
    expect(report(from: 'gen:2').to_h['unknowns']).to include(
      include('kind' => 'unclassified_metadata', 'metadata_keys' => ['custom_fact'])
    )
  end

  it 'keeps base removal and head current evidence separate for an affected typed identity' do
    base = publish(1, [unit('Removed', 'model'), unit('Current', 'model'), unit('Caller', 'service')])
    head = publish(2, [unit('Current', 'model', 'changed'), unit('Caller', 'service')])
    write_graph(base, 'Removed', 'old', 0.1)
    write_graph(head, 'Current', 'new', 0.8)
    data = report.to_h
    expect(data['affected'].map { |item| item.values_at('identifier', 'type', 'endpoint', 'generation', 'weight') })
      .to eq([['Caller', 'service', 'from', 1, 0.1], ['Caller', 'service', 'to', 2, 0.8]])
    expect(data['affected'].map { |item| item['paths'].first['edges'].first['via'] }).to eq(%w[old new])
  end

  it 'records unavailable sources even on unchanged typed units' do
    publish(1, [unit('Example', 'model', nil)])
    publish(2, [unit('Example', 'model', nil)])
    expect(report.to_h['unknowns']).to include(
      include('kind' => 'source_unavailable', 'endpoint' => 'from', 'identifier' => 'Example'),
      include('kind' => 'source_unavailable', 'endpoint' => 'to', 'identifier' => 'Example')
    )
  end

  it 'retains unclassified source unknowns even when edges have a known category' do
    publish(1, [unit('Example', 'js_module')])
    changed = unit('Example', 'js_module', 'changed').merge('dependencies' => [{ 'target' => 'Other' }])
    publish(2, [changed])
    expect(report.to_h['unknowns']).to include(include('kind' => 'unclassified_source', 'type' => 'js_module'))
  end

  it 'keeps hash facets separate from semantic categories and labels unclassified metadata' do
    publish(1, [unit('Example', 'model', 'same', { 'custom_fact' => 1 })])
    publish(2, [unit('Example', 'model', 'same', { 'custom_fact' => 2 })])
    data = report.to_h
    expect(data['changed'].first).to include('facets' => ['metadata'], 'categories' => [])
    expect(data['unknowns']).to include(include('kind' => 'unclassified_metadata', 'identifier' => 'Example'))
  end

  it 'serializes a detached immutable report deterministically without source bodies' do
    publish(1, [unit('Example', 'model')])
    publish(2, [unit('Example', 'model', 'new source')])
    result = report
    expect(result.to_json).to eq(report.to_json)
    expect(JSON.parse(result.to_json)).to eq(result.to_h)
    expect(result.to_h['changed'].first).not_to have_key('source_code')
    expect { result.to_h['changed'].clear }.to raise_error(FrozenError)
    expect(result.to_h['schema_version']).to eq(1)
  end
  it 'keeps related tables from removed and current roots bound to their own endpoints' do
    table = unit('table:primary.widgets', 'database_table', 'schema',
                 { 'table_name' => 'widgets', 'database' => 'primary' })
    edge = { 'target' => table['identifier'], 'type' => 'database_table', 'via' => 'table' }
    before = unit('OldWidget', 'model').merge('dependencies' => [edge])
    after = unit('NewWidget', 'model').merge('dependencies' => [edge])
    publish(1, [before, table])
    publish(2, [after, table])
    result = report
    expect(result.to_h['tables'].map { |item| item.values_at('identifier', 'endpoint', 'generation') })
      .to eq([['table:primary.widgets', 'from', 1], ['table:primary.widgets', 'to', 2]])
    expect(result.to_h['tables'].map { |item| item['evidence'].first.dig('source', 'identifier') })
      .to eq(%w[OldWidget NewWidget])
    expect(result.to_h['coverage']).to include('tables' => 'partial', 'templates' => 'partial', 'tests' => 'partial')
    expect(result.to_h['unknowns']).not_to include(include('kind' => 'not_computed', 'feature' => 'tables'))
    expect(result.to_json).to eq(report.to_json)
    expect(result.to_h['tables'].first['evidence']).to be_frozen
  end

  it 'exposes related focus evidence without manufacturing a range or complete coverage' do
    template = unit('view:widgets/show', 'view_template')
    publish(1, [template])
    data = described_class.focus(@root, identities: [template.slice('identifier', 'type')]).to_h
    expect(data['range']).to be_nil
    expect(data['templates'].first).to include('identifier' => template['identifier'], 'endpoint' => 'to',
                                               'generation' => 1, 'evidence' => [{ 'kind' => 'selected_unit' }])
    expect(data['coverage']).to include('complete' => false, 'templates' => 'partial')
  end
end
