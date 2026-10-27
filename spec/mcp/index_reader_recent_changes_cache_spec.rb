# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'timeout'
require 'tmpdir'
require 'woods/mcp/index_reader'

RSpec.describe Woods::MCP::IndexReader, 'recent changes generation reads' do
  let(:root) { Dir.mktmpdir('woods-recent-changes-cache') }
  let(:generation) { Woods::Generation.new(output_dir: root) }
  let(:reader) { described_class.new(root) }

  after { FileUtils.remove_entry(root) }

  def unit(identifier, type, date: '2026-01-01', path: nil, author: 'author@example.test', metadata: :default)
    metadata = { 'git' => { 'last_modified' => date, 'last_author' => author } } if metadata == :default
    { 'identifier' => identifier, 'type' => type, 'file_path' => path || "app/#{type}/#{identifier}.rb",
      'metadata' => metadata, 'source_code' => "large body #{identifier} #{'x' * 2048}" }
  end

  def filename(identifier)
    base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    "#{base}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
  end

  def write_index(path, buckets, legacy: false)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'manifest.json'), JSON.generate('git_sha' => 'same-sha'))
    buckets.each do |directory, units|
      type_path = File.join(path, directory)
      FileUtils.mkdir_p(type_path)
      units.each { |data| File.write(File.join(type_path, filename(data.fetch('identifier'))), JSON.generate(data)) }
      entries = units.map do |data|
        legacy ? { 'identifier' => data.fetch('identifier') } : data.slice('identifier', 'type', 'file_path')
      end
      File.write(File.join(type_path, '_index.json'), JSON.generate(entries))
    end
  end

  def write_payload(name, buckets, legacy: false)
    write_index(File.join(root, 'payloads', name), buckets, legacy: legacy)
  end

  def publish(name)
    generation.bump!(payload: "payloads/#{name}")
  end

  def capture_unit_opens
    opened = []
    allow(reader).to receive(:open_unit).and_wrap_original do |original, path, &block|
      opened << path
      original.call(path, &block)
    end
    opened
  end

  def row(identifier, type, date, path: "app/#{type}/#{identifier}.rb", author: 'author@example.test')
    { identifier: identifier, type: type, file_path: path, last_modified: date, author: author }
  end

  it 'reads a selected bucket once per immutable generation, including an empty history result' do
    models = 80.times.map { |i| unit("Model#{i}", 'model', metadata: {}) }
    controllers = 65.times.map { |i| unit("Controller#{i}", 'controller') }
    write_payload('one', { 'models' => models, 'controllers' => controllers })
    publish('one')
    opened = capture_unit_opens

    expect(reader.recent_changes(types: ['model'])).to eq([])
    expect(opened.size).to eq(80)
    opened.clear
    expect(reader.recent_changes(types: ['model'])).to eq([])
    expect(opened.size).to eq(0)

    expect(reader.recent_changes(types: ['controller']).size).to eq(10)
    expect(opened.size).to eq(65)
    opened.clear
    expect(reader.recent_changes(types: %w[controller model], limit: 3).size).to eq(3)
    expect(opened.size).to eq(0)
    expect(reader.instance_variable_get(:@unit_cache).size).to be <= described_class::MAX_UNIT_CACHE
  end

  it 'preserves ordering, ties, duplicate filters, family types, missing metadata and typed collisions' do
    write_payload('one', {
                    'models' => [unit('Shared', 'model', date: '2026-04-01', author: nil),
                                 unit('NoMetadata', 'model', metadata: nil),
                                 unit('NoGit', 'model', metadata: {}),
                                 unit('NoDate', 'model', metadata: { 'git' => {} })],
                    'controllers' => [unit('Shared', 'controller', date: '2026-04-01'),
                                      unit('Earlier', 'controller', date: '2026-03-01')],
                    'graphql' => [unit('Mutation', 'graphql_mutation', date: '2026-05-01')]
                  }, legacy: true)
    publish('one')
    expected = [row('Mutation', 'graphql', '2026-05-01', path: 'app/graphql_mutation/Mutation.rb'),
                row('Shared', 'controller', '2026-04-01'),
                row('Shared', 'model', '2026-04-01', author: nil),
                row('Earlier', 'controller', '2026-03-01')]

    2.times { expect(reader.recent_changes).to eq(expected) }
    expect(reader.recent_changes(types: [])).to eq([])
    expect(reader.recent_changes(types: ['unknown'])).to eq([])
    expect(reader.recent_changes(types: ['graphql_mutation'])).to eq([])
    expect(reader.recent_changes(types: %w[controller model model])).to eq(
      [row('Shared', 'model', '2026-04-01', author: nil), row('Shared', 'model', '2026-04-01', author: nil),
       row('Shared', 'controller', '2026-04-01'), row('Earlier', 'controller', '2026-03-01')]
    )
    expect(reader.recent_changes(limit: 2)).to eq(expected.first(2))
    expect(reader.recent_changes(limit: 0)).to eq([])
    expect { reader.recent_changes(limit: -1) }.to raise_error(ArgumentError)
    expect { reader.recent_changes(types: 'model') }.to raise_error(NoMethodError)
  end

  it 'does not let callers mutate a cached result through returned hashes or strings' do
    write_payload('one', { 'models' => [unit('One', 'model')] })
    publish('one')
    result = reader.recent_changes.first
    result[:identifier].replace('changed')
    result[:last_modified].replace('changed')
    result[:file_path].replace('changed')
    result[:author].replace('changed')

    expect(reader.recent_changes).to eq([row('One', 'model', '2026-01-01')])
  end

  it 'preserves and detaches nested JSON values from older indexes' do
    date = %w[2026 01]
    path = { 'parts' => ['app', 'model.rb'] }
    author = { 'names' => ['developer'] }
    write_payload('one', { 'models' => [unit('One', 'model', date: date, path: path, author: author)] })
    publish('one')
    expected = row('One', 'model', date, path: path, author: author)
    result = reader.recent_changes.first
    expect(result).to eq(expected)
    result[:last_modified].first.replace('changed')
    result[:file_path]['parts'].first.replace('changed')
    result[:author]['names'] << 'changed'

    expect(reader.recent_changes).to eq([expected])
  end

  it 'discards summaries on a new generation even at the same git SHA, with additions and removals' do
    write_payload('one', { 'models' => [unit('Removed', 'model'), unit('Retained', 'model', date: '2026-01-01')] })
    models = [
      unit('Retained', 'model', date: '2026-03-01'), unit('Added', 'model', date: '2026-02-01'),
      unit('Untracked', 'model', metadata: {})
    ]
    write_payload('two', { 'models' => models })
    publish('one')
    opened = capture_unit_opens
    expect(reader.recent_changes.map { |r| r[:identifier] }).to contain_exactly('Removed', 'Retained')
    opened.clear
    publish('two')

    expect(reader.recent_changes).to eq([row('Retained', 'model', '2026-03-01'), row('Added', 'model', '2026-02-01')])
    expect(opened.size).to eq(3)
    opened.clear
    expect(reader.recent_changes.size).to eq(2)
    expect(opened).to be_empty
  end

  it 'invalidates when a different token publishes the same generation number' do
    write_payload('one', { 'models' => [unit('Before', 'model')] })
    write_payload('two', { 'models' => [unit('After', 'model')] })
    publish('one')
    expect(reader.recent_changes.first[:identifier]).to eq('Before')
    File.write(generation.path, JSON.generate('number' => 1, 'token' => 'another-writer', 'payload' => 'payloads/two'))

    expect(reader.recent_changes.first[:identifier]).to eq('After')
  end

  it 'refreshes old tokenless generation markers and legacy index entries' do
    write_payload('one', { 'models' => [unit('Before', 'model')] }, legacy: true)
    write_payload('two', { 'models' => [unit('After', 'model')] }, legacy: true)
    File.write(generation.path, JSON.generate('number' => 1, 'payload' => 'payloads/one'))
    expect(reader.recent_changes.first[:identifier]).to eq('Before')
    File.write(generation.path, JSON.generate('number' => 2, 'payload' => 'payloads/two'))

    expect(reader.recent_changes.first[:identifier]).to eq('After')
  end

  it 'keeps both already-summarized and newly read buckets on the pinned payload' do
    write_payload('one', { 'models' => [unit('OldModel', 'model')],
                           'controllers' => [unit('OldController', 'controller')] })
    write_payload('two', { 'models' => [unit('NewModel', 'model')],
                           'controllers' => [unit('NewController', 'controller')] })
    publish('one')
    expect(reader.recent_changes(types: ['model']).first[:identifier]).to eq('OldModel')

    seen = reader.with_pinned_generation do
      publish('two')
      reader.recent_changes(types: %w[model controller]).map { |r| r[:identifier] }
    end
    expect(seen).to eq(%w[OldController OldModel])
    expect(reader.recent_changes.map { |r| r[:identifier] }).to eq(%w[NewController NewModel])
  end

  it 'finishes an in-flight scan on the old generation before the next request adopts the new one' do
    write_payload('one', { 'models' => [unit('Old', 'model'), unit('AlsoOld', 'model')] })
    write_payload('two', { 'models' => [unit('New', 'model')] })
    publish('one')
    entered = Queue.new
    resume = Queue.new
    allow(reader).to receive(:open_unit).and_wrap_original do |original, path, &block|
      if Thread.current[:block_first_unit]
        Thread.current[:block_first_unit] = false
        entered << true
        resume.pop
      end
      original.call(path, &block)
    end
    first = Thread.new do
      Thread.current[:block_first_unit] = true
      reader.recent_changes(types: ['model']).map { |r| r[:identifier] }
    end
    Timeout.timeout(10) { entered.pop }
    publish('two')
    second = Thread.new { reader.recent_changes(types: ['model']).map { |r| r[:identifier] } }
    resume << true

    expect(Timeout.timeout(10) { first.value }).to eq(%w[AlsoOld Old])
    expect(Timeout.timeout(10) { second.value }).to eq(['New'])
  ensure
    resume << true if first&.alive?
    first&.join(1)
    second&.join(1)
  end

  it 'shares one completed bucket scan between concurrent requests' do
    write_payload('one', { 'models' => 80.times.map { |i| unit("Model#{i}", 'model') } })
    publish('one')
    entered = Queue.new
    resume = Queue.new
    opened = []
    allow(reader).to receive(:open_unit).and_wrap_original do |original, path, &block|
      opened << path
      if Thread.current[:block_first_unit]
        Thread.current[:block_first_unit] = false
        entered << true
        resume.pop
      end
      original.call(path, &block)
    end
    first = Thread.new do
      Thread.current[:block_first_unit] = true
      reader.recent_changes(types: ['model'])
    end
    Timeout.timeout(10) { entered.pop }
    second = Thread.new { reader.recent_changes(types: ['model']) }
    resume << true

    first_result = Timeout.timeout(10) { first.value }
    expect(Timeout.timeout(10) { second.value }).to eq(first_result)
    expect(opened.size).to eq(80)
  ensure
    resume << true if first&.alive?
    first&.join(1)
    second&.join(1)
  end

  it 'keeps the previous summary when adoption fails and retries after the marker is repaired' do
    write_payload('one', { 'models' => [unit('Old', 'model')] })
    write_payload('two', { 'models' => [unit('New', 'model')] })
    publish('one')
    opened = capture_unit_opens
    expect(reader.recent_changes.first[:identifier]).to eq('Old')
    old_marker = File.read(generation.path)
    opened.clear
    File.write(generation.path, JSON.generate('number' => 2, 'token' => 'bad', 'payload' => 'payloads/missing'))
    2.times { expect { reader.recent_changes }.to raise_error(Woods::Generation::InvalidMarker) }
    File.write(generation.path, old_marker)

    expect(reader.recent_changes.first[:identifier]).to eq('Old')
    expect(opened).to be_empty
    publish('two')
    expect(reader.recent_changes.first[:identifier]).to eq('New')
  end

  it 'does not cache a partial bucket when reading an entry fails' do
    first_unit = unit('First', 'model')
    second_unit = unit('Second', 'model')
    write_payload('one', { 'models' => [first_unit, second_unit] })
    publish('one')
    path = File.join(root, 'payloads/one/models', filename('Second'))
    File.write(path, '{invalid')
    expect { reader.recent_changes(types: ['model']) }.to raise_error(JSON::ParserError)
    File.write(path, JSON.generate(second_unit))

    expect(reader.recent_changes(types: ['model']).map { |r| r[:identifier] }).to eq(%w[Second First])
  end

  it 'clears the cached summaries on an explicit exclusive reload' do
    write_payload('one', { 'models' => [unit('One', 'model')] })
    publish('one')
    opened = capture_unit_opens
    reader.recent_changes
    opened.clear
    reader.with_exclusive_reload { nil }

    expect(reader.recent_changes).to eq([row('One', 'model', '2026-01-01')])
    expect(opened.size).to eq(1)
  end

  it 'preserves the active summary after an aborted reload transaction' do
    write_payload('one', { 'models' => [unit('One', 'model')] })
    publish('one')
    opened = capture_unit_opens
    reader.recent_changes
    opened.clear
    expect { reader.with_exclusive_generation { raise IOError, 'reload aborted before swap' } }
      .to raise_error(IOError, 'reload aborted before swap')

    expect(reader.recent_changes).to eq([row('One', 'model', '2026-01-01')])
    expect(opened).to be_empty
    expect { reader.with_exclusive_reload { raise IOError, 'reload failed after clearing' } }
      .to raise_error(IOError, 'reload failed after clearing')
    expect(reader.recent_changes).to eq([row('One', 'model', '2026-01-01')])
    expect(opened.size).to eq(1)
  end

  [false, true].each do |with_marker|
    it "rereads mutable flat units on each request #{with_marker ? 'with' : 'without'} a generation marker" do
      write_index(root, { 'models' => [unit('Mutable', 'model')] })
      generation.bump! if with_marker
      opened = capture_unit_opens
      expect(reader.recent_changes.first[:last_modified]).to eq('2026-01-01')
      path = File.join(root, 'models', filename('Mutable'))
      File.write(path, JSON.generate(unit('Mutable', 'model', date: '2026-12-31-longer')))

      expect(reader.recent_changes.first[:last_modified]).to eq('2026-12-31-longer')
      expect(opened.size).to eq(2)
    end
  end
end
