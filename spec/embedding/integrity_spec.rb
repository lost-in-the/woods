# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/filename_utils'
require 'woods/dependency_graph'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/embedding/fake'
require 'woods/storage/snapshotter'
require 'woods/mcp/index_reader'

RSpec.describe 'Embedding publication integrity' do
  around do |example|
    Dir.mktmpdir('woods-embedding-integrity') do |dir|
      @root = dir
      example.run
    end
  end

  let(:provider) { Woods::Embedding::Provider::Fake.new(dims: 8) }
  let(:units) do
    10.times.map do |i|
      unit = Woods::ExtractedUnit.new(type: :model, identifier: "Unit#{i}", file_path: "app/models/unit#{i}.rb")
      unit.source_code = "class Unit#{i}; def value; #{i}; end; end"
      unit.to_h.transform_keys(&:to_s)
    end
  end

  def indexer(vector_store: Woods::Storage::VectorStore::InMemory.new, **options)
    Woods::Embedding::Indexer.new(provider: provider, text_preparer: Woods::Embedding::TextPreparer.new,
                                  vector_store: vector_store, metadata_store: Woods::Storage::MetadataStore::InMemory.new,
                                  output_dir: @root, chunker: nil, **options)
  end

  def filename(identifier)
    Object.new.extend(Woods::FilenameUtils).collision_safe_filename(identifier)
  end

  def publish(records, name: 'gen-1')
    payload = File.join(@root, 'payloads', name)
    counts = {}
    records.group_by { |unit| unit.fetch('type') }.each do |type, group|
      bucket = { 'factory' => 'factories', 'database_view' => 'database_views' }.fetch(type, "#{type}s")
      write_bucket(File.join(payload, bucket), group)
      counts[bucket] = group.size
    end
    File.write(File.join(payload, 'manifest.json'), JSON.generate(counts: counts))
    Woods::Generation.new(output_dir: @root).bump!(payload: "payloads/#{name}")
    payload
  end

  def write_bucket(directory, group)
    FileUtils.mkdir_p(directory)
    group.each { |unit| File.write(File.join(directory, filename(unit.fetch('identifier'))), JSON.generate(unit)) }
    entries = group.map { |unit| { identifier: unit['identifier'] } }
    File.write(File.join(directory, '_index.json'), JSON.generate(entries))
  end

  def persisted
    artifact = Woods::IndexArtifact.new(@root)
    vectors = Woods::Storage::Snapshotter::Vector.load_or_empty(artifact)
    metadata = Woods::Storage::Snapshotter::Metadata.load_or_empty(artifact)
    # Hydration stamps a new in-memory updated_at. Compare the public records
    # and exact persisted bytes, including the original serialized timestamps.
    records = metadata.each_entry.map { |id, _record| [id, metadata.find(id)] }
    files = %w[metadata.msgpack vectors.bin vectors.idx].to_h do |name|
      [name, File.binread(artifact.latest_dump_path.join(name))]
    end
    { ids: vectors.each_entry.to_a.map(&:first).sort, metadata: records, files: files,
      checkpoint: File.binread(File.join(@root, 'checkpoint.json')), dump: artifact.latest_dump_path.to_s }
  end

  %i[corrupt missing missing_index wrong_type count_mismatch bad_manifest bad_marker missing_payload
     null_pointer omitted_pointer missing_marker].each do |damage|
    [false, true].each do |force|
      it "refuses #{damage} before mutation, including purge override=#{force}" do
        payload = publish(units)
        indexer.index_all
        before = persisted
        file = File.join(payload, 'models', filename('Unit0'))
        case damage
        when :corrupt then File.write(file, '{broken')
        when :missing then File.unlink(file)
        when :missing_index then File.unlink(File.join(payload, 'models', '_index.json'))
        when :wrong_type then File.write(file, JSON.generate(units.first.merge('type' => 'service')))
        when :count_mismatch then File.write(File.join(payload, 'manifest.json'), JSON.generate(counts: { models: 9 }))
        when :bad_manifest then File.write(File.join(payload, 'manifest.json'), JSON.generate(counts: nil))
        when :bad_marker then File.write(File.join(@root, 'generation.json'), '{broken')
        when :missing_payload then FileUtils.rm_rf(payload)
        when :null_pointer, :omitted_pointer
          marker = { number: 1, token: 'damaged' }
          marker[:payload] = nil if damage == :null_pointer
          File.write(File.join(@root, 'generation.json'), JSON.generate(marker))
        when :missing_marker then File.unlink(File.join(@root, 'generation.json'))
        end
        calls = provider.calls.size
        previous = ENV.fetch('WOODS_ALLOW_PURGE', nil)
        begin
          ENV['WOODS_ALLOW_PURGE'] = force ? '1' : '0'
          expect { indexer.index_incremental }.to raise_error(Woods::Error, /incomplete/i)
        ensure
          previous ? ENV['WOODS_ALLOW_PURGE'] = previous : ENV.delete('WOODS_ALLOW_PURGE')
        end
        expect(provider.calls.size).to eq(calls)
        expect(persisted).to eq(before)
      end
    end
  end

  it 'reconciles genuine published deletion below the purge threshold' do
    publish(units)
    indexer.index_all
    publish(units.drop(1), name: 'gen-2')
    expect(indexer.index_incremental).to eq(processed: 0, skipped: 9, errors: 0)
    expect(persisted[:ids]).not_to include('Unit0')
  end

  it 'preserves flat legacy unit and summary-file support' do
    File.write(File.join(@root, 'unit.json'), JSON.generate(units.first))
    File.write(File.join(@root, 'manifest.json'), JSON.generate(unit_count: 1))
    expect(indexer.index_all[:processed]).to eq(1)
    expect(indexer.index_incremental[:skipped]).to eq(1)
  end

  [false, true].each do |explicit_nil|
    it "preserves legacy flat generation markers with explicit nil payload=#{explicit_nil}" do
      marker = { number: 1, token: 'legacy' }
      marker[:payload] = nil if explicit_nil
      File.write(File.join(@root, 'generation.json'), JSON.generate(marker))
      File.write(File.join(@root, 'arbitrary.json'), JSON.generate(units.first))
      expect(indexer.index_all[:processed]).to eq(1)
      expect(indexer.index_incremental[:skipped]).to eq(1)
    end
  end

  ['', " \n\t"].each do |empty|
    it "retires vectors when current source becomes #{empty.inspect} and checkpoints the no-content state" do
      publish(units)
      indexer.index_all
      changed = units.map(&:dup)
      changed.first.merge!('source_code' => empty, 'source_hash' => Digest::SHA256.hexdigest(empty), 'chunks' => [])
      publish(changed, name: 'gen-2')
      calls = provider.calls.size
      expect(indexer.index_incremental).to eq(processed: 0, skipped: 9, errors: 0)
      after = persisted
      expect(after[:ids]).not_to include('Unit0')
      expect(after[:metadata].to_h.fetch('Unit0')['source_code']).to eq(empty)
      expect(JSON.parse(after[:checkpoint]).fetch('Unit0')).to eq(Digest::SHA256.hexdigest(empty))
      expect(indexer.index_incremental).to eq(processed: 0, skipped: 10, errors: 0)
      expect(persisted).to eq(after)
      expect(provider.calls.size).to eq(calls)
    end
  end

  it 'removes every old chunk only for the source-empty typed sibling' do
    records = %w[factory database_view].map do |type|
      units.first.merge('type' => type, 'identifier' => 'reports', 'source_code' => type, 'source_hash' => type,
                        'chunks' => [{ content: 'first chunk' }, { content: 'second chunk' }])
    end
    publish(records)
    indexer.index_all
    records.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''), 'chunks' => [])
    publish(records, name: 'gen-2')
    indexer.index_incremental
    sibling = Woods::StorageIdentity.key('reports', 'database_view')
    expect(persisted[:ids]).to contain_exactly("#{sibling}#chunk_0", "#{sibling}#chunk_1")
    expect(persisted[:metadata].size).to eq(2)
    expect(indexer.index_incremental[:skipped]).to eq(2)
  end
  it 'retains a vectorless typed identity after sibling deletion, then removes its vanished metadata' do
    records = %w[factory database_view].map do |type|
      units.first.merge('type' => type, 'identifier' => 'reports', 'source_code' => type, 'source_hash' => type)
    end + units.drop(1)
    publish(records)
    indexer.index_all
    records.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''))
    publish(records, name: 'gen-2')
    indexer.index_incremental
    records.delete_at(1)
    publish(records, name: 'gen-3')
    indexer.index_incremental
    key = Woods::StorageIdentity.key('reports', 'factory')
    expect(persisted[:metadata].to_h.keys).to contain_exactly(key, *units.drop(1).map { |unit| unit['identifier'] })
    records.shift
    publish(records, name: 'gen-4')
    indexer.index_incremental
    expect(persisted[:metadata].to_h.keys).to match_array(units.drop(1).map { |unit| unit['identifier'] })
  end

  it 'validates full embedding before replacing any existing snapshot' do
    payload = publish(units)
    indexer.index_all
    before = persisted
    File.unlink(File.join(payload, 'models', filename('Unit0')))
    expect { indexer.index_all }.to raise_error(Woods::Error, /incomplete/i)
    expect(persisted).to eq(before)
  end

  it 'keeps corpus reads on one generation when publication advances mid-read' do
    publish(units)
    changed = units.map { |unit| unit.merge('source_code' => 'replacement', 'source_hash' => 'replacement') }
    allow(Woods::MCP::IndexReader).to receive(:new).and_wrap_original do |constructor, *args|
      reader = constructor.call(*args)
      allow(reader).to receive(:each_unit).and_wrap_original do |method|
        Enumerator.new do |output|
          moved = false
          method.call do |unit|
            unless moved
              publish(changed, name: 'gen-2')
              moved = true
            end
            output << unit
          end
        end
      end
      reader
    end
    indexer.index_all
    expect(persisted[:metadata].to_h.values.map { |unit| unit['source_code'] }).to match_array(units.map { |unit|
      unit['source_code']
    })
    expect(provider.calls.flatten).not_to include(a_string_including('replacement'))
  end

  # Represents the durable each_id/delete contract without the dump interface.
  # Real PostgreSQL and Qdrant coverage remains in the opt-in backend lane.
  let(:durable_store) do
    Class.new do
      attr_reader :entries

      def initialize
        @entries = {}
      end

      def store_batch(entries)
        entries.each { |entry| @entries[entry[:id]] = entry }
      end

      def each_id(&block)
        @entries.keys.each(&block)
      end

      def delete(id)
        @entries.delete(id)
      end
    end.new
  end

  it 'refuses incomplete native input before writing or deleting durable entries' do
    payload = publish(units)
    indexer(vector_store: durable_store).index_all
    before = Marshal.dump(durable_store.entries)
    checkpoint = File.binread(File.join(@root, 'checkpoint.json'))
    File.unlink(File.join(payload, 'models', filename('Unit0')))
    expect { indexer(vector_store: durable_store).index_all }.to raise_error(Woods::Error, /incomplete/i)
    expect(Marshal.dump(durable_store.entries)).to eq(before)
    expect(File.binread(File.join(@root, 'checkpoint.json'))).to eq(checkpoint)
  end

  it 'reconciles zero-text durable vectors and skips them on subsequent fresh runs' do
    publish(units)
    indexer(vector_store: durable_store).index_all
    changed = units.map(&:dup)
    changed.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''))
    publish(changed, name: 'gen-2')
    calls = provider.calls.size
    indexer(vector_store: durable_store).index_incremental
    expect(durable_store.entries.keys).not_to include('Unit0')
    expect(indexer(vector_store: durable_store).index_incremental[:skipped]).to eq(10)
    expect(provider.calls.size).to eq(calls)
  end

  it 'does not checkpoint a zero-text transition if durable enumeration fails' do
    publish(units)
    indexer(vector_store: durable_store).index_all
    before = Marshal.dump(durable_store.entries)
    checkpoint = File.binread(File.join(@root, 'checkpoint.json'))
    changed = units.map(&:dup)
    changed.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''))
    publish(changed, name: 'gen-2')
    allow(durable_store).to receive(:each_id).and_raise('enumeration unavailable')
    expect { indexer(vector_store: durable_store).index_incremental }
      .to raise_error(Woods::Error, /Cannot reconcile source-empty units/)
    expect(Marshal.dump(durable_store.entries)).to eq(before)
    expect(File.binread(File.join(@root, 'checkpoint.json'))).to eq(checkpoint)
    allow(durable_store).to receive(:each_id).and_call_original
    indexer(vector_store: durable_store).index_incremental
    expect(durable_store.entries.keys).not_to include('Unit0')
  end

  it 'retires empty-source vectors when a direct caller reuses its store for full indexing' do
    publish(units)
    instance = indexer
    instance.index_all
    changed = units.map(&:dup)
    changed.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''))
    publish(changed, name: 'gen-2')
    instance.index_all
    expect(persisted[:ids]).not_to include('Unit0')
  end

  it 'keeps old zero-text vectors and checkpoints when a later batch fails' do
    publish(units)
    indexer(vector_store: durable_store).index_all
    before = Marshal.dump(durable_store.entries)
    checkpoint = File.binread(File.join(@root, 'checkpoint.json'))
    changed = units.map(&:dup)
    changed.first.merge!('source_code' => '', 'source_hash' => Digest::SHA256.hexdigest(''))
    changed.last.merge!('source_code' => 'new source', 'source_hash' => 'new source')
    publish(changed, name: 'gen-2')
    allow(provider).to receive(:embed_batch).and_raise('provider failure')
    expect do
      indexer(vector_store: durable_store,
              batch_size: 1).index_incremental
    end.to raise_error(Woods::Error, /provider failure/)
    expect(Marshal.dump(durable_store.entries)).to eq(before)
    expect(File.binread(File.join(@root, 'checkpoint.json'))).to eq(checkpoint)
  end
end
