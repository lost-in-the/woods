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
end
