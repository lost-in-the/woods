# frozen_string_literal: true

# End-to-end smoke for the retrieval-evaluation harness (#212 / B-099).
#
# The harness has existed since the evaluation subsystem landed and has never
# once been runnable: its rake file was never loaded, and it called four
# `Woods.*` store accessors that do not exist. `spec/evaluation/` covered the
# metrics arithmetic, but nothing drove QuerySet -> Retriever -> Evaluator ->
# Metrics together, so "the harness works" was never a tested claim.
#
# That mattered most exactly when it was missing: #185 fixed four compounding
# ranking defects, and there was no way to measure whether retrieval improved.
#
# Fully offline — the `:fake` provider (#178) gives deterministic vectors with
# no API key and no Ollama, so this runs in the default unit suite.

require 'spec_helper'
require 'woods'
require 'woods/retriever'
require 'woods/embedding/fake'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'
require 'woods/evaluation/query_set'
require 'woods/evaluation/evaluator'
require 'woods/evaluation/baseline_runner'
require 'woods/evaluation/metrics'
require 'woods/evaluation/report_generator'

RSpec.describe 'Evaluation harness (offline)', :integration do
  let(:provider) { Woods::Embedding::Provider::Fake.new(dims: 32) }
  let(:vector_store) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { Woods::Storage::MetadataStore::InMemory.new }
  let(:graph_store) { Woods::Storage::GraphStore::Memory.new }

  # A tiny corpus whose text is distinctive enough that the fake provider's
  # deterministic vectors separate the units.
  let(:corpus) do
    {
      'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb',
                  'source_code' => 'class User; has_many :orders; end' },
      'Order' => { 'type' => 'model', 'file_path' => 'app/models/order.rb',
                   'source_code' => 'class Order; belongs_to :user; end' },
      'PaymentService' => { 'type' => 'service', 'file_path' => 'app/services/payment_service.rb',
                            'source_code' => 'class PaymentService; def charge; end; end' }
    }
  end

  let(:retriever) do
    Woods::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: provider
    )
  end

  let(:query_set) do
    Woods::Evaluation::QuerySet.new(
      queries: [
        Woods::Evaluation::QuerySet::Query.new(
          query: 'how does payment charging work',
          expected_units: ['PaymentService'], intent: :understand, scope: :focused, tags: ['billing']
        ),
        Woods::Evaluation::QuerySet::Query.new(
          query: 'where is the user model',
          expected_units: ['User'], intent: :locate, scope: :pinpoint, tags: ['models']
        )
      ]
    )
  end

  before do
    corpus.each do |identifier, data|
      metadata_store.store(identifier, data)
      vector_store.store(identifier, provider.embed(data['source_code']), { type: data['type'] })
    end
  end

  it 'runs every query and reports one result each' do
    report = Woods::Evaluation::Evaluator.new(retriever: retriever, query_set: query_set).evaluate

    expect(report.results.size).to eq(2)
    expect(report.results.map(&:query))
      .to contain_exactly('how does payment charging work', 'where is the user model')
  end

  it 'produces numeric aggregate metrics rather than nil or empty' do
    report = Woods::Evaluation::Evaluator.new(retriever: retriever, query_set: query_set).evaluate

    expect(report.aggregates).not_to be_empty
    report.aggregates.each_value do |value|
      expect(value).to be_a(Numeric), "expected a number, got #{value.inspect}"
      expect(value).not_to be_nan if value.is_a?(Float)
    end
  end

  it 'retrieves units and accounts for the tokens they cost' do
    report = Woods::Evaluation::Evaluator.new(retriever: retriever, query_set: query_set).evaluate

    expect(report.results).to all(have_attributes(tokens_used: a_value >= 0))
    expect(report.results.flat_map(&:retrieved_units)).not_to be_empty
  end

  it 'writes a report file the ReportGenerator can produce' do
    report = Woods::Evaluation::Evaluator.new(retriever: retriever, query_set: query_set).evaluate

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'eval_report.json')
      Woods::Evaluation::ReportGenerator.new.save(report, path, metadata: { 'query_set' => 'inline' })

      expect(File.exist?(path)).to be(true)
      parsed = JSON.parse(File.read(path))
      expect(parsed).to include('aggregates')
    end
  end

  # BaselineRunner called `all_identifiers` on the configured metadata store
  # while no adapter implemented it, so every strategy raised NoMethodError.
  describe 'baselines' do
    %i[grep random file_level].each do |strategy|
      it "runs the #{strategy} baseline and scores it" do
        runner = Woods::Evaluation::BaselineRunner.new(metadata_store: metadata_store, seed: 42)

        results = runner.run('payment charging', strategy: strategy, limit: 3)

        expect(results).to be_an(Array)
        expect(Woods::Evaluation::Metrics.recall(results, ['PaymentService'])).to be_between(0.0, 1.0)
      end
    end

    it 'finds the obviously-matching unit with the grep baseline' do
      runner = Woods::Evaluation::BaselineRunner.new(metadata_store: metadata_store)

      expect(runner.run('PaymentService', strategy: :grep, limit: 3)).to include('PaymentService')
    end
  end

  # Ground-truth annotations are only comparable with pipeline output if both
  # speak the same vocabulary (#218 / B-105).
  it 'annotates queries in the vocabulary the classifier produces' do
    classifier = Woods::Retrieval::QueryClassifier.new

    query_set.queries.each do |query|
      expect(Woods::Evaluation::QuerySet::VALID_INTENTS).to include(query.intent)
      expect(Woods::Evaluation::QuerySet::VALID_SCOPES).to include(query.scope)

      classification = classifier.classify(query.query)
      expect(Woods::Evaluation::QuerySet::VALID_INTENTS).to include(classification.intent)
      expect(Woods::Evaluation::QuerySet::VALID_SCOPES).to include(classification.scope)
    end
  end
end
