# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/embedding/openai'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/storage/vector_store'

RSpec.describe 'OpenAI requests for chunk-heavy indexing' do
  let(:provider) { Woods::Embedding::Provider::OpenAI.new(api_key: 'test-key', dimensions: 2) }
  let(:vector_store) { Woods::Storage::VectorStore::InMemory.new }
  let(:http) { instance_double(Net::HTTP) }
  let(:requests) { [] }
  let(:chunk_count) { 2050 }
  let(:fail_second_request) { false }
  let(:change_second_dimensions) { false }
  let(:indexer) do
    Woods::Embedding::Indexer.new(provider: provider, vector_store: vector_store,
                                  text_preparer: Woods::Embedding::TextPreparer.new,
                                  output_dir: @output_dir)
  end

  around do |example|
    Dir.mktmpdir('woods-openai-batch') do |dir|
      @output_dir = dir
      example.run
    end
  end

  before do
    unit = {
      type: 'model', identifier: 'Chunked', source_code: 'class Chunked; end', source_hash: 'source',
      chunks: Array.new(chunk_count) { |index| { chunk_index: index, content: "chunk value #{index}" } }
    }
    File.write(File.join(@output_dir, 'chunked.json'), JSON.generate(unit))
    allow(provider).to receive(:http_client).and_return(http)
    allow(http).to receive(:request) do |request|
      texts = JSON.parse(request.body).fetch('input')
      requests << texts
      raise Woods::Error, 'second request failed' if fail_second_request && requests.size == 2

      data = texts.each_with_index.map do |text, index|
        vector = [text.match(/chunk value (\d+)/)[1].to_f, 1.0]
        vector << 2.0 if change_second_dimensions && requests.size == 2
        { index: index, embedding: vector }
      end
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(response).to receive(:body).and_return(JSON.generate(data: data.reverse))
      response
    end
  end

  it 'caps each HTTP request and stores all chunk vectors in original order' do
    stats = indexer.index_all

    expect(requests.map(&:size)).to eq(([36] * 56) + [34])
    expect(stats[:processed]).to eq(chunk_count)
    vectors = vector_store.each_entry.to_h { |id, vector, _metadata| [id, vector] }
    chunk_count.times do |index|
      expect(vectors.fetch("Chunked#chunk_#{index}")).to eq([index.to_f, 1.0])
    end
    checkpoint = JSON.parse(File.read(File.join(@output_dir, 'checkpoint.json')))
    expect(checkpoint.fetch('Chunked')).to eq('source')
  end

  context 'when a later request fails' do
    let(:chunk_count) { 40 }
    let(:fail_second_request) { true }

    it 'stores no partial vectors or successful checkpoint' do
      expect { indexer.index_all }.to raise_error(Woods::Error, /second request failed/)
      expect(vector_store.count).to eq(0)
      expect(File).not_to exist(File.join(@output_dir, 'checkpoint.json'))
      expect(File).not_to exist(File.join(@output_dir, 'dumps', 'latest'))
    end
  end

  context 'when response dimensions change between requests' do
    let(:chunk_count) { 40 }
    let(:change_second_dimensions) { true }

    it 'rejects the combined vectors before committing any of them' do
      expect { indexer.index_all }.to raise_error(Woods::Error, /dimension/)
      expect(vector_store.count).to eq(0)
      expect(File).not_to exist(File.join(@output_dir, 'checkpoint.json'))
    end
  end
end
