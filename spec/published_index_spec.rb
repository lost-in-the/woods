# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/published_index'

RSpec.describe Woods::PublishedIndex do
  let(:fixture_dir) { File.expand_path('fixtures/woods', __dir__) }

  describe 'over a flat index' do
    let(:reader) { described_class.new(fixture_dir) }

    after { reader.close }

    it 'reports generation 0 and the index root as payload_dir' do
      expect(reader.generation_number).to eq(0)
      expect(reader.payload_dir.to_s).to eq(fixture_dir)
    end

    it 'looks up a unit by identifier with string keys' do
      expect(reader.unit('Post')).to include('type' => 'model', 'identifier' => 'Post')
      expect(reader.unit('Nope')).to be_nil
    end

    it 'lists index entries with their type' do
      models = reader.units(type: 'model')

      expect(models.map { |e| e['identifier'] }).to contain_exactly('Post', 'Comment')
      expect(models.map { |e| e['type'] }.uniq).to eq(['model'])
      expect(reader.units.size).to be > models.size
    end

    it 'iterates edges with from, to, via, and attributes' do
      edges = reader.edges

      expect(edges).to include(from: 'Comment', to: 'Post', via: nil, through: nil, disable_joins: false)
      expect(reader.edges(via: 'belongs_to')).to eq([])
      expect { |probe| reader.each_edge(&probe) }.to yield_control.at_least(:once)
    end

    it 'answers dependents from the reverse index' do
      expect(reader.dependents_of('Post')).to contain_exactly('Comment', 'PostsController')
    end

    it 'builds the table to database map from model units' do
      expect(reader.table_database_map).to eq({})
    end

    it 'checksums the pinned payload manifest.json' do
      expected = Digest::SHA256.file(File.join(fixture_dir, 'manifest.json')).hexdigest

      expect(reader.external_dependency_checksum).to eq(expected)
    end
  end

  describe 'over a published generation index' do
    around do |example|
      Dir.mktmpdir('woods-published-index') do |dir|
        @index_dir = dir
        %w[1 2].each do |number|
          payload = File.join(dir, 'payloads', "gen-#{number}")
          FileUtils.mkdir_p(payload)
          FileUtils.cp_r(Dir[File.join(fixture_dir, '*')], payload)
          manifest = JSON.parse(File.read(File.join(payload, 'manifest.json')))
          manifest['total_units'] = number.to_i
          File.write(File.join(payload, 'manifest.json'), JSON.generate(manifest))
        end
        File.write(File.join(dir, 'generation.json'),
                   JSON.generate('number' => 2, 'token' => 'abc', 'payload' => 'payloads/gen-2'))
        example.run
      end
    end

    it 'reads the published generation by default' do
      current = described_class.new(@index_dir)

      expect(current.generation_number).to eq(2)
      expect(current.payload_dir.to_s).to eq(File.join(@index_dir, 'payloads', 'gen-2'))
      current.close
    end

    it 'pins an older retained generation on request' do
      pinned = described_class.new(@index_dir, generation: 1)

      expect(pinned.generation_number).to eq(1)
      expect(pinned.payload_dir.to_s).to eq(File.join(@index_dir, 'payloads', 'gen-1'))
      expect(pinned.unit('Post')).to include('identifier' => 'Post')
      pinned.close
    end

    it 'lists the published generations' do
      expect(described_class.available_generations(@index_dir)).to eq([1, 2])
    end

    it 'raises for a generation numbered above the published pointer' do
      expect { described_class.new(@index_dir, generation: 9) }.to raise_error(ArgumentError, /gen-9/)
    end

    it 'checksums the pinned payload manifest.json, not generation.json' do
      current = described_class.new(@index_dir)
      expected = Digest::SHA256.file(File.join(@index_dir, 'payloads', 'gen-2', 'manifest.json')).hexdigest

      expect(current.external_dependency_checksum).to eq(expected)
      current.close
    end

    it 'never lists a generation directory ahead of the pointer' do
      unpublished = File.join(@index_dir, 'payloads', 'gen-3')
      FileUtils.mkdir_p(unpublished)
      FileUtils.cp_r(Dir[File.join(fixture_dir, '*')], unpublished)

      expect(described_class.available_generations(@index_dir)).to eq([1, 2])
      expect { described_class.new(@index_dir, generation: 3) }.to raise_error(ArgumentError, /gen-3/)
    end

    it 'never lists a directory whose publication failed (manifest missing)' do
      FileUtils.rm(File.join(@index_dir, 'payloads', 'gen-2', 'manifest.json'))

      expect(described_class.available_generations(@index_dir)).to eq([1])
      expect { described_class.new(@index_dir) }.to raise_error(ArgumentError, /gen-2/)
    end

    it 'raises CorruptPointerError, not an empty list, when generation.json will not parse' do
      pointer_path = File.join(@index_dir, 'generation.json')
      File.write(pointer_path, '{not valid json')

      expect { described_class.available_generations(@index_dir) }
        .to raise_error(Woods::PublishedIndex::CorruptPointerError, /#{Regexp.escape(pointer_path)}/)
      expect { described_class.new(@index_dir) }
        .to raise_error(Woods::PublishedIndex::CorruptPointerError, /#{Regexp.escape(pointer_path)}/)
    end

    it 'releases the retention lock when construction fails after the lock is acquired' do
      allow(Woods::MCP::IndexReader).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.new(@index_dir, generation: 1) }.to raise_error(StandardError, 'boom')

      manifest_path = File.join(@index_dir, 'payloads', 'gen-1', 'manifest.json')
      File.open(manifest_path, File::RDONLY) do |file|
        expect(file.flock(File::LOCK_EX | File::LOCK_NB)).to eq(0)
        file.flock(File::LOCK_UN)
      end
    end

    it 'holds a generation open against retention while pinned' do
      opened = described_class.new(@index_dir, generation: 1)

      removed = Woods::PayloadStore.new(@index_dir).prune(keep: 1, protect: 2)

      expect(removed).to eq([])
      expect(File.directory?(File.join(@index_dir, 'payloads', 'gen-1'))).to be(true)
      expect(opened.unit('Post')).to include('identifier' => 'Post')

      opened.close
    end

    it 'releases the retention pin once the generation is retired' do
      opened = described_class.new(@index_dir, generation: 1)
      opened.close

      removed = Woods::PayloadStore.new(@index_dir).prune(keep: 1, protect: 2)

      expect(removed).to eq([1])
      expect(File.directory?(File.join(@index_dir, 'payloads', 'gen-1'))).to be(false)
    end

    it 'yields a pinned reader in block form and releases the lock in ensure' do
      result = described_class.open(@index_dir, generation: 1) do |index|
        expect(index.generation_number).to eq(1)
        :done
      end

      expect(result).to eq(:done)

      removed = Woods::PayloadStore.new(@index_dir).prune(keep: 1, protect: 2)
      expect(removed).to eq([1])
    end

    it 'releases the lock in ensure when the block raises' do
      expect do
        described_class.open(@index_dir, generation: 1) { raise 'boom' }
      end.to raise_error(RuntimeError, 'boom')

      removed = Woods::PayloadStore.new(@index_dir).prune(keep: 1, protect: 2)
      expect(removed).to eq([1])
    end
  end

  describe '#table_database_map with database metadata' do
    it 'maps each model table to its database' do
      Dir.mktmpdir('woods-published-index-db') do |dir|
        FileUtils.cp_r(Dir[File.join(fixture_dir, '*')], dir)
        post = File.join(dir, 'models', 'Post_a5554622.json')
        data = JSON.parse(File.read(post))
        data['metadata']['database'] = 'primary'
        File.write(post, JSON.generate(data))

        index = described_class.new(dir)
        expect(index.table_database_map).to eq('posts' => 'primary')
        index.close
      end
    end
  end

  describe '#unit with an explicit type' do
    it 'reads that type directly, bypassing a same-identifier collision in another type' do
      Dir.mktmpdir('woods-published-index-typed-unit') do |dir|
        File.write(File.join(dir, 'manifest.json'), JSON.generate('total_units' => 2))

        digest = Digest::SHA256.hexdigest('Foo')[0, 8]
        filename = "Foo_#{digest}.json"

        model_dir = File.join(dir, 'models')
        FileUtils.mkdir_p(model_dir)
        File.write(File.join(model_dir, '_index.json'),
                   JSON.generate([{ 'identifier' => 'Foo', 'file_path' => 'app/models/foo.rb', 'namespace' => nil }]))
        File.write(File.join(model_dir, filename), JSON.generate(
                                                     'type' => 'model', 'identifier' => 'Foo',
                                                     'file_path' => 'app/models/foo.rb',
                                                     'metadata' => { 'table_name' => 'foos', 'database' => 'primary' }
                                                   ))

        service_dir = File.join(dir, 'services')
        FileUtils.mkdir_p(service_dir)
        File.write(File.join(service_dir, '_index.json'),
                   JSON.generate([{ 'identifier' => 'Foo', 'file_path' => 'app/services/foo.rb',
                                    'namespace' => nil }]))
        File.write(File.join(service_dir, filename), JSON.generate(
                                                       'type' => 'service', 'identifier' => 'Foo',
                                                       'file_path' => 'app/services/foo.rb', 'metadata' => {}
                                                     ))

        index = described_class.new(dir)

        # TYPE_DIRS lists services after models, so the untyped, identifier-only
        # lookup lands on the service: exactly the collision `type:` exists to avoid.
        expect(index.unit('Foo')).to include('type' => 'service')
        expect(index.unit('Foo', type: 'model')).to include('type' => 'model', 'identifier' => 'Foo')
        expect(index.unit('Foo', type: 'service')).to include('type' => 'service', 'identifier' => 'Foo')
        expect(index.table_database_map).to eq('foos' => 'primary')

        index.close
      end
    end
  end

  describe 'edges from more than one type sharing an identifier' do
    it 'does not collapse a variant edge into its primary-type twin' do
      Dir.mktmpdir('woods-published-index-variants') do |dir|
        File.write(File.join(dir, 'manifest.json'), JSON.generate('total_units' => 2))
        File.write(File.join(dir, 'dependency_graph.json'), JSON.generate(
                                                              'nodes' => {
                                                                'Foo' => { 'type' => 'model' },
                                                                'Bar' => { 'type' => 'model' }
                                                              },
                                                              'edges' => { 'Foo' => ['Bar'], 'Bar' => [] },
                                                              'reverse' => { 'Foo' => [], 'Bar' => ['Foo'] },
                                                              'variants' => [
                                                                { 'identifier' => 'Foo', 'type' => 'service',
                                                                  'edges' => ['Bar'] }
                                                              ]
                                                            ))

        index = described_class.new(dir)
        matches = index.edges.select { |e| e[:from] == 'Foo' && e[:to] == 'Bar' }

        expect(matches.size).to eq(2)
        index.close
      end
    end
  end
end
