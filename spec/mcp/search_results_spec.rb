# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/search_results'

RSpec.describe Woods::MCP::SearchResults do
  def match(results, identifier, type: 'model')
    results.add(identifier: identifier, type: type, match_field: 'identifier')
  end

  it 'does not treat a filled page as proof of additional matches' do
    results = described_class.new(limit: 1)
    match(results, 'Post')
    expect(results.result_limit_reached?).to be(false)

    expect { results.response }.to raise_error(ArgumentError, 'Search has not finished')
    expect(results.finish.response.fetch(:completeness)).to include(status: 'complete', has_more: false,
                                                                    total_matches: 1)
  end

  it 'retains one lookahead match and distinguishes shared names by type' do
    results = described_class.new(limit: 1)
    match(results, 'Post')
    match(results, 'Post')
    expect(results.result_limit_reached?).to be(false)
    match(results, 'Post', type: 'service')
    expect(results.result_limit_reached?).to be(true)
    match(results, 'Ignored')

    expect(results.response[:results].size).to eq(1)
    expect(results.response.fetch(:completeness)).to include(status: 'partial', has_more: true,
                                                             total_matches: nil, matched_lower_bound: 2)
  end

  %w[scan_budget regex_timeout].each do |reason|
    it "keeps totals unknown after #{reason}, retaining previously found matches" do
      results = described_class.new(limit: 2)
      match(results, 'Post')
      results.stop(reason)

      expect(results.response(note: 'existing advisory')).to include(partial: true, note: 'existing advisory')
      expect(results.response.fetch(:completeness)).to eq(status: 'partial', reason: reason, has_more: nil,
                                                          total_matches: nil, matched_lower_bound: 1)
    end
  end
end
