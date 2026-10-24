# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/published_index'
require 'woods/payload_store'
require 'woods/generation'
require 'woods/filename_utils'

# W-13 (#763): readers limited to the published-index API (Woods Map, cops,
# scripts) look up which entry points run through a typed unit, and read one
# flow document, in the reader's pinned generation without resolving payload
# paths themselves.
RSpec.describe 'Woods::PublishedIndex flow readers' do
  let(:index) { Dir.mktmpdir('woods-published-flows') }
  let(:store) { Woods::PayloadStore.new(index) }
  let(:inverse) do
    {
      'OrdersController' => { 'controller' => ['OrdersController#create'] },
      'Shared' => { 'model' => ['OrdersController#create'],
                    'service' => ['OrdersController#create', 'OrdersController#show'] }
    }
  end
  let(:document) do
    { 'entry_point' => 'OrdersController#create', 'max_depth' => 5,
      'route' => { 'verb' => 'POST', 'path' => '/orders' },
      'steps' => [{ 'unit' => 'OrdersController#create', 'type' => 'controller', 'operations' => [] },
                  { 'unit' => 'Shared', 'type' => 'model', 'operations' => [] }] }
  end

  after { FileUtils.rm_rf(index) }

  def publish(number, flows: true)
    payload = store.create(number)
    File.write(payload.join('manifest.json'), '{"counts":{}}')
    File.write(payload.join('dependency_graph.json'), '{}')
    write_flows(payload) if flows
    Woods::Generation.new(output_dir: index).bump!(payload: Woods::PayloadStore.name_for(number))
    payload
  end

  def write_flows(payload)
    dir = payload.join('flows')
    FileUtils.mkdir_p(dir)
    filename = Woods::FilenameUtils.flow_filename('OrdersController', 'create')
    File.write(dir.join(filename), JSON.generate(document))
    File.write(dir.join('flow_index.json'), JSON.generate('OrdersController#create' => "flows/#{filename}"))
    File.write(dir.join('by_unit.json'), JSON.generate(inverse))
  end

  def with_reader(generation: nil, &block)
    Woods::PublishedIndex.open(index, generation: generation, &block)
  end

  describe '#flow_entry_points' do
    it 'answers by identifier and actual type, never flattening a shared identifier' do
      publish(1)
      with_reader do |reader|
        expect(reader.flow_entry_points('Shared', type: 'service'))
          .to eq(['OrdersController#create', 'OrdersController#show'])
        expect(reader.flow_entry_points('Shared', type: :model)).to eq(['OrdersController#create'])
        expect(reader.flow_entry_points('OrdersController', type: 'controller')).to eq(['OrdersController#create'])
      end
    end

    it 'returns an empty list for a unit no expanded flow step reaches' do
      publish(1)
      with_reader do |reader|
        expect(reader.flow_entry_points('Shared', type: 'job')).to eq([])
        expect(reader.flow_entry_points('Elsewhere', type: 'model')).to eq([])
      end
    end

    it 'returns nil, not an empty list, when the generation publishes no inverse' do
      publish(1, flows: false)
      with_reader { |reader| expect(reader.flow_entry_points('Shared', type: 'model')).to be_nil }
    end

    it 'reads the generation the reader pinned, not the one published later' do
      publish(1)
      with_reader(generation: 1) do |reader|
        publish(2, flows: false)
        expect(reader.flow_entry_points('Shared', type: 'model')).to eq(['OrdersController#create'])
      end
    end

    it 'returns a copy the caller may change without affecting later answers' do
      publish(1)
      with_reader do |reader|
        reader.flow_entry_points('Shared', type: 'service') << 'Injected#entry'
        expect(reader.flow_entry_points('Shared', type: 'service')).not_to include('Injected#entry')
      end
    end

    it 'raises for a malformed inverse instead of reporting no membership' do
      payload = publish(1)
      malformed = { 'Shared' => { 'model' => 'OrdersController#create' } }
      File.write(payload.join('flows/by_unit.json'), JSON.generate(malformed))
      with_reader do |reader|
        expect { reader.flow_entry_points('Shared', type: 'model') }.to raise_error(IOError, /inverse/)
      end
    end

    it 'raises for an inverse that is not a JSON object' do
      payload = publish(1)
      File.write(payload.join('flows/by_unit.json'), '[]')
      with_reader { |reader| expect { reader.flow_entry_points('Shared', type: 'model') }.to raise_error(IOError) }
    end

    it 'refuses a symlinked inverse' do
      payload = publish(1)
      outside = File.join(index, 'outside.json')
      File.write(outside, JSON.generate(inverse))
      File.delete(payload.join('flows/by_unit.json'))
      File.symlink(outside, payload.join('flows/by_unit.json'))
      with_reader { |reader| expect { reader.flow_entry_points('Shared', type: 'model') }.to raise_error(IOError) }
    end
  end

  describe '#flow_document' do
    it 'reads one indexed flow document as published, string keyed' do
      publish(1)
      with_reader do |reader|
        expect(reader.flow_document('OrdersController#create')).to eq(document)
      end
    end

    it 'returns nil for an entry point the flow index does not list' do
      publish(1)
      with_reader { |reader| expect(reader.flow_document('OrdersController#destroy')).to be_nil }
    end

    it 'returns nil when the generation has no precomputed flows' do
      publish(1, flows: false)
      with_reader { |reader| expect(reader.flow_document('OrdersController#create')).to be_nil }
    end

    it 'raises when an indexed document names another entry point' do
      payload = publish(1)
      filename = Woods::FilenameUtils.flow_filename('OrdersController', 'create')
      File.write(payload.join('flows', filename), JSON.generate(document.merge('entry_point' => 'Other#x')))
      with_reader { |reader| expect { reader.flow_document('OrdersController#create') }.to raise_error(IOError) }
    end

    it 'raises when an indexed document is missing' do
      payload = publish(1)
      File.delete(payload.join('flows', Woods::FilenameUtils.flow_filename('OrdersController', 'create')))
      with_reader { |reader| expect { reader.flow_document('OrdersController#create') }.to raise_error(IOError) }
    end
  end
end
