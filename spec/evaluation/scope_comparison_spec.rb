# frozen_string_literal: true

require 'spec_helper'
require_relative '../../bench/evaluation/scope_comparison'

RSpec.describe ScopeComparison do
  let(:root) { File.expand_path('../../bench/evaluation', __dir__) }
  let(:capture) { JSON.parse(File.read(File.join(root, 'scope_comparison_capture.json'))) }
  let(:corpus) { JSON.parse(File.read(File.join(root, 'corpus.json'))) }

  it 'keeps the original questions, gold labels and budgets in every paired condition' do
    queries = corpus.fetch('queries').to_h { |query| [query.fetch('id'), query] }
    expect(capture.fetch('results').size).to eq(112)
    capture.fetch('results').each do |row|
      query = queries.fetch(row.fetch('id'))
      expect(row.fetch('expected')).to eq(query.fetch('expected_units'))
      expect(row.fetch('budget')).to eq(query.fetch('budget'))
    end
  end

  it 'retains byte-identical unscoped contexts from the approved lexical comparison' do
    previous = JSON.parse(File.read(File.join(root, 'lexical_comparison_capture.json'))).fetch('results')
    capture.fetch('results').select { |row| row['condition'].end_with?('_unscoped') }.each do |row|
      mode = row.fetch('condition').delete_suffix('_unscoped')
      old = previous.find { |entry| entry['id'] == row['id'] && entry['condition'] == mode }
      expect(row.fetch('context_sha256')).to eq(old.fetch('context_sha256'))
    end
  end

  it 'keeps questions without an explicit domain word as unscoped controls' do
    expect(described_class.paths_for('trace article')).to eq([])
    expect(described_class.paths_for('trace Billing::Invoice')).to include('app/models/billing')
  end
end
