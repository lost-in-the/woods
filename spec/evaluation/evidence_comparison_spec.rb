# frozen_string_literal: true

require 'spec_helper'
require_relative '../../bench/evaluation/evidence_comparison'

RSpec.describe EvidenceComparison do
  let(:root) { File.expand_path('../../bench/evaluation', __dir__) }
  let(:capture) { JSON.parse(File.read(File.join(root, 'evidence_comparison_capture.json'))) }
  let(:corpus) { JSON.parse(File.read(File.join(root, 'corpus.json'))) }

  it 'keeps the original questions, gold labels and budgets in all six evidence conditions' do
    queries = corpus.fetch('queries').to_h { |query| [query.fetch('id'), query] }
    expect(capture.fetch('results').size).to eq(168)
    capture.fetch('results').each do |row|
      query = queries.fetch(row.fetch('id'))
      expect(row.fetch('expected')).to eq(query.fetch('expected_units'))
      expect(row.fetch('budget')).to eq(query.fetch('budget'))
    end
  end

  it 'preserves the approved full contexts byte for byte' do
    prior = JSON.parse(File.read(File.join(root, 'lexical_comparison_capture.json'))).fetch('results')
    capture.fetch('results').select { |row| row['condition'].end_with?('_full') }.each do |row|
      mode = row.fetch('condition').delete_suffix('_full')
      previous = prior.find { |entry| entry['id'] == row['id'] && entry['condition'] == mode }
      expect(row.fetch('context_sha256')).to eq(previous.fetch('context_sha256'))
    end
  end

  it 'makes missing implementation spans visible instead of treating unit recall as span relevance' do
    compact = capture.fetch('results').select { |row| row['condition'].end_with?('_compact') }
    expect(compact.flat_map { |row| row.fetch('evidence_units') }).not_to be_empty
    compact.flat_map { |row| row.fetch('evidence_units') }.each do |unit|
      expect(unit.fetch('selected_spans')).to be >= 0
      expect(unit.fetch('omitted_spans')).to be >= 0
    end
  end
end
