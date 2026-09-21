# frozen_string_literal: true

require 'spec_helper'
require 'woods/retriever'
require 'woods/storage/metadata_store'
require 'woods/storage_identity'

RSpec.describe 'Lexical shortlist and included-source counts' do
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:retriever) do
    Woods::Retriever.new(metadata_store: metadata, vector_store: nil, graph_store: nil,
                         embedding_provider: nil, mode: :lexical)
  end

  def add_units(count, package: 'packs/billing', repetitions: 1)
    count.times do |i|
      name = "#{package.split('/').last.capitalize}#{i}"
      metadata.store(Woods::StorageIdentity.key(name, 'service'), {
                       identifier: name, type: 'service', file_path: "#{package}/app/services/#{name}.rb",
                       source_code: "class #{name}; def countword; #{'nil; ' * repetitions}end; end",
                       metadata: { package: package }
                     })
    end
  end

  def expect_counts(result, candidates:)
    expect(result.context).to include("sources included: #{result.sources.size};",
                                      "candidates considered: #{candidates}; candidate limit: 20;")
    expect(result.trace.candidate_count).to eq(candidates)
    expect(result.context).not_to include('ranked top 20')
    expect_budget(result)
  end

  def expect_budget(result)
    expect(result.tokens_used).to eq((result.context.length / 4.0).ceil)
    expect(result.context.length).to be <= result.budget * 4
  end

  %w[full compact outline].each do |mode|
    [0, 3, 25].each do |count|
      it "reports the actual shortlist and sources for #{count} matches in #{mode} mode" do
        add_units(count)
        result = retriever.retrieve('countword', evidence: mode, budget: 20_000)

        expect_counts(result, candidates: [count, 20].min)
        expect(result.sources.size).to eq([count, 20].min)
        expect(result.context.include?('No lexical matches.')).to eq(count.zero?)
      end
    end

    it "distinguishes matches that fit no sources from no matches in #{mode} mode" do
      add_units(25, repetitions: 100)
      result = retriever.retrieve('countword', evidence: mode, budget: 40)

      expect_counts(result, candidates: 20)
      expect(result.sources).to be_empty
      expect(result.context).not_to include('No lexical matches.')
    end

    it "charges final count text at tiny and boundary budgets in #{mode} mode" do
      add_units(25, repetitions: 100)
      [1, 10, 20, 30, 35, 40, 50, 80, 100, 150, 300].each do |budget|
        result = retriever.retrieve('countword', evidence: mode, budget: budget)
        expect(result.tokens_used).to eq((result.context.length / 4.0).ceil)
        expect(result.context.length).to be <= budget * 4
        if (reported = result.context[/sources included: (\d+);/, 1])
          expect(reported.to_i).to eq(result.sources.size)
        end
      end
    end

    it "agrees with scope attribution after package and path filtering in #{mode} mode" do
      add_units(25, package: 'packs/other')
      add_units(3)
      result = retriever.retrieve('countword', evidence: mode, budget: 40,
                                               packages: ['packs/billing'], source_paths: ['packs/billing/app'])

      expect_counts(result, candidates: 3)
      expect(result.sources).to be_empty
      expect(result.applied_scope).to include(eligible_units: 3, candidate_count: 3, returned_units: 0,
                                              outcome: :matched)
    end
  end

  it 'reports one included source while retaining ranking order and the charged truncation notice' do
    add_units(25, repetitions: 500)
    complete = retriever.retrieve('countword', budget: 100_000)
    result = retriever.retrieve('countword', budget: 150)

    expect_counts(result, candidates: 20)
    expect(result.sources.size).to eq(1)
    expect(result.sources.first[:identifier]).to eq(complete.sources.first[:identifier])
    expect(result.sources.first[:truncated]).to be(true)
    expect(result.context).to include('[Published evidence truncated; use lookup for the full unit.]')
  end
end
