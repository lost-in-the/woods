# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/lexical_assembler'
require 'woods/retrieval/search_executor'

# In full evidence, one long top source used to take the whole budget and
# end assembly, so a lexical answer could carry a single source. Each source
# now gets a fair share of what is left, and assembly continues after a
# truncated one.
RSpec.describe Woods::Retrieval::LexicalAssembler do
  def candidate(identifier, source)
    unit = { 'identifier' => identifier, 'type' => 'model', 'file_path' => "app/models/#{identifier.downcase}.rb",
             'source_code' => source, 'metadata' => {} }
    Woods::Retrieval::SearchExecutor::Candidate.new(identifier: identifier, score: 1.0, source: :lexical,
                                                    metadata: unit, matched_fields: ['source_code:widget'])
  end

  def assemble(candidates, budget: 2000)
    described_class.new.assemble(candidates: candidates, budget: budget)
  end

  it 'keeps several sources when the top one alone would fill the budget' do
    candidates = [candidate('Widget', "widget\n" * 5000)] +
                 Array.new(5) { |i| candidate("Gadget#{i}", "widget #{i}\n" * 20) }
    result = assemble(candidates)

    expect(result.sources.size).to eq(6)
    expect(result.sources.first).to include(identifier: 'Widget', truncated: true)
    expect(result.sources.drop(1).map { |source| source[:truncated] }).to all(be(false))
    expect(result.context).to include('sources included: 6')
    expect(result.tokens_used).to be <= 2000
  end

  it 'gives the whole budget to a single long source' do
    result = assemble([candidate('Widget', "widget\n" * 5000)])

    expect(result.sources.size).to eq(1)
    expect(result.context.length).to be > 2000 * 4 * 0.9
    expect(result.tokens_used).to be <= 2000
  end

  it 'keeps short sources whole and in rank order' do
    candidates = Array.new(3) { |i| candidate("Gadget#{i}", "widget #{i}") }
    result = assemble(candidates)

    expect(result.sources.map { |source| source[:identifier] }).to eq(%w[Gadget0 Gadget1 Gadget2])
    expect(result.sources.map { |source| source[:truncated] }).to all(be(false))
  end
  describe 'runtime metadata evidence' do
    def empty_effects
      { 'columns_written' => [], 'jobs_enqueued' => [], 'services_called' => [] }
    end

    def runtime_candidate(metadata, source: "class Order\nend\n")
      unit = { 'identifier' => 'Order', 'type' => 'model', 'file_path' => 'app/models/order.rb',
               'source_code' => source, 'metadata' => metadata }
      Woods::Retrieval::SearchExecutor::Candidate.new(identifier: 'Order', score: 1.0, source: :lexical,
                                                      metadata: unit, matched_fields: ['runtime:receipt'])
    end

    let(:metadata) do
      { 'callbacks' => [
          { 'type' => 'before_save', 'filter' => 'autosave_associated_records_for_customer',
            'origin' => 'framework', 'conditions' => {}, 'side_effects' => empty_effects },
          { 'type' => 'after_commit', 'filter' => 'enqueue_receipt', 'origin' => 'app', 'conditions' => {},
            'side_effects' => empty_effects.merge('jobs_enqueued' => ['ReceiptJob']) },
          { 'type' => 'after_save', 'filter' => 'touch_parent', 'origin' => 'framework',
            'side_effects' => empty_effects.merge('columns_written' => ['updated_at']) }
        ],
        'associations' => [{ 'name' => 'customer', 'type' => 'belongs_to', 'through' => nil, 'options' => {} }],
        'scopes' => [],
        'table_name' => 'orders' }
    end

    let(:context) { assemble([runtime_candidate(metadata)]).context }

    it 'writes one line of JSON per entry, without empty values' do
      expect(context).to include(%(  {"name":"customer","type":"belongs_to"}))
      expect(context).to include('table_name: "orders"')
      expect(context).not_to include('scopes')
      expect(context).not_to include('"conditions"')
    end

    it 'leaves out framework callbacks that record no side effect, and says how many' do
      expect(context).not_to include('autosave_associated_records_for_customer')
      expect(context).to include('(1 framework callback with no recorded side effects omitted; lookup lists them)')
    end

    it 'keeps application callbacks and framework callbacks that record a side effect' do
      expect(context).to include('"filter":"enqueue_receipt"').and include('"jobs_enqueued":["ReceiptJob"]')
      expect(context).to include('"filter":"touch_parent"').and include('"columns_written":["updated_at"]')
    end

    it 'still names the callbacks when only framework ones were recorded' do
      only_framework = { 'callbacks' => [metadata['callbacks'].first] }

      expect(assemble([runtime_candidate(only_framework)]).context)
        .to include("callbacks:\n  (1 framework callback with no recorded side effects omitted")
    end

    it 'leaves room for the source of a unit with many framework callbacks' do
      noisy = { 'callbacks' => Array.new(40) { metadata['callbacks'].first } }
      result = assemble([runtime_candidate(noisy, source: "def renew\n  charge!\nend\n")], budget: 300)

      expect(result.context).to include('def renew')
      expect(result.sources.first).to include(truncated: false)
    end

    it 'shows the source alone when no runtime field matched' do
      expect(assemble([candidate('Widget', "widget\n")]).context).not_to include('Published runtime metadata')
    end
  end
end
