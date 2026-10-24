# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods/published_index'
require 'woods/payload_store'
require 'woods/generation'
require 'woods/mcp/server'

# W-11 (#761): pins are durable operational state. Readers that may only go
# through Woods' published-index API (Woods Map, cops, scripts) and agents
# reading woods_status need to see them without touching index files.
RSpec.describe 'Generation retention pins for readers' do
  let(:index) { Dir.mktmpdir('woods-retention-pins-reader') }
  let(:store) { Woods::PayloadStore.new(index) }

  after { FileUtils.rm_rf(index) }

  def publish(number)
    payload = store.create(number)
    File.write(payload.join('manifest.json'), '{"counts":{}}')
    File.write(payload.join('dependency_graph.json'), '{}')
    Woods::Generation.new(output_dir: index).bump!(payload: Woods::PayloadStore.name_for(number))
  end

  describe 'Woods::PublishedIndex.retention_pins' do
    it 'is empty for an index that has never recorded a pin' do
      publish(1)
      expect(Woods::PublishedIndex.retention_pins(index)).to eq([])
    end

    it 'is empty for a flat index without operational state' do
      expect(Woods::PublishedIndex.retention_pins(index)).to eq([])
    end

    it 'lists persistent pins in ascending order and follows unpinning' do
      (1..3).each { |number| publish(number) }
      store.pin(3)
      store.pin(1)
      expect(Woods::PublishedIndex.retention_pins(Pathname.new(index))).to eq([1, 3])

      store.unpin(3)
      expect(Woods::PublishedIndex.retention_pins(index)).to eq([1])
    end

    it 'keeps a pin whose payload was removed externally, for the caller to intersect' do
      (1..2).each { |number| publish(number) }
      store.pin(1)
      FileUtils.rm_rf(store.path_for(1))
      expect(Woods::PublishedIndex.retention_pins(index)).to eq([1])
      expect(Woods::PublishedIndex.available_generations(index)).to eq([2])
    end

    it 'raises instead of reporting no pins when the state is malformed' do
      publish(1)
      File.write(File.join(index, Woods::GenerationPins::FILENAME), '{"version":1,"generations":"1"}')
      expect { Woods::PublishedIndex.retention_pins(index) }.to raise_error(IOError, /malformed/)
    end
  end

  describe 'woods_status index.retention_pins' do
    let(:reader) { double('reader', manifest: { 'extracted_at' => nil, 'counts' => {} }) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WOODS_NO_UPDATE_CHECK').and_return(nil)
      allow(Open3).to receive(:capture3).and_return(['', '', instance_double(Process::Status, success?: false)])
    end

    def status_index
      Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: index)[:index]
    end

    it 'lists the persistent pins beside the published generation' do
      (1..2).each { |number| publish(number) }
      store.pin(1)
      expect(status_index).to include(generation: 2, retention_pins: [1])
      expect(status_index).not_to have_key(:retention_pins_error)
    end

    it 'reports an empty list when nothing is pinned' do
      publish(1)
      expect(status_index[:retention_pins]).to eq([])
    end

    it 'reports unknown pins with the reason instead of an empty list when the state is malformed' do
      publish(1)
      File.write(File.join(index, Woods::GenerationPins::FILENAME), '{')
      expect(status_index).to include(retention_pins: nil,
                                      retention_pins_error: 'Generation pin state is unreadable or malformed')
      expect(status_index).to include(generation: 1)
    end

    it 'omits pins when the server has no index directory' do
      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: nil)
      expect(status[:index]).not_to have_key(:retention_pins)
    end
  end
end
