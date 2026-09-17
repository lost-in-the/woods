# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/retriever'
require 'woods/storage/metadata_store'
require 'woods/storage/vector_store'

RSpec.describe 'Final retrieval context token accounting' do
  let(:metadata_store) { Woods::Storage::MetadataStore::InMemory.new }
  let(:formatter) { nil }
  let(:retriever) do
    Woods::Retriever.new(
      metadata_store: metadata_store,
      vector_store: Woods::Storage::VectorStore::InMemory.new,
      graph_store: nil, embedding_provider: nil, formatter: formatter
    )
  end

  before do
    metadata_store.store('User', {
                           identifier: 'User', type: 'model', file_path: 'app/models/user.rb',
                           source_code: "class User\n  def active? = true\nend"
                         })
  end

  [nil, ['model']].each do |types|
    context "with types: #{types.inspect}" do
      [nil, ->(text) { "# Postprocessed context\n\n#{text}" }].each do |format|
        context "#{format ? 'with' : 'without'} a formatter" do
          let(:formatter) { format }

          it 'counts the delivered context and keeps trace accounting consistent' do
            result = retriever.retrieve('find exactly User', budget: 300, types: types)

            expect(result.tokens_used).to eq((result.context.length / 4.0).ceil)
            expect(result.trace.tokens_used).to eq(result.tokens_used)
            expect(result.sources.map { |source| source[:identifier] }).to eq(['User'])
            expect(result.type_rank_context&.dig('model', :source)).to eq(types ? :in_top_k : nil)
          end
        end
      end
    end
  end

  context 'when formatting removes the assembled context' do
    let(:formatter) { ->(_text) { '' } }

    it 'reports zero tokens for the empty delivered context' do
      result = retriever.retrieve('find exactly User', budget: 300)

      expect(result.context).to eq('')
      expect(result.tokens_used).to eq(0)
      expect(result.trace.tokens_used).to eq(0)
    end
  end

  context 'with a configured chars-per-token ratio' do
    before do
      allow_any_instance_of(Woods::Retriever).to receive(:infer_chars_per_token).and_return(1.5)
    end

    it 'uses the assembly ratio for the final type-rank table too' do
      result = retriever.retrieve('find exactly User', budget: 1000, types: ['model'])

      expect(result.tokens_used).to eq((result.context.length / 1.5).ceil)
      expect(result.trace.tokens_used).to eq(result.tokens_used)
    end
  end

  context 'with an injected counter' do
    let(:formatter) { ->(text) { "# Custom heading\n\n#{text}" } }
    let(:counter) { double('TokenCounter') }

    before do
      allow(counter).to receive(:count) { |text| text.scan(/\w+|[^\w\s]/).size }
      allow_any_instance_of(Woods::Retriever).to receive(:infer_token_counter).and_return(counter)
    end

    it 'counts the complete formatted context with the same counter as assembly' do
      result = retriever.retrieve('find exactly User', budget: 1000, types: ['model'])

      expect(result.tokens_used).to eq(result.context.scan(/\w+|[^\w\s]/).size)
      expect(result.trace.tokens_used).to eq(result.tokens_used)
      expect(counter).to have_received(:count).with(result.context)
    end
  end
end
