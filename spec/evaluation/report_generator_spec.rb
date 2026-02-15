# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'codebase_index'
require 'codebase_index/evaluation/evaluator'
require 'codebase_index/evaluation/report_generator'

RSpec.describe CodebaseIndex::Evaluation::ReportGenerator do
  let(:generator) { described_class.new }

  let(:query_results) do
    [
      CodebaseIndex::Evaluation::Evaluator::QueryResult.new(
        query: 'How does User model work?',
        expected_units: %w[User UserConcern],
        retrieved_units: %w[User UserConcern Post],
        scores: {
          precision_at5: 0.4,
          precision_at10: 0.2,
          recall: 1.0,
          mrr: 1.0,
          context_completeness: 1.0,
          token_efficiency: 0.6667
        },
        tokens_used: 500
      ),
      CodebaseIndex::Evaluation::Evaluator::QueryResult.new(
        query: 'Trace order creation',
        expected_units: %w[Order OrdersController],
        retrieved_units: %w[Order Product],
        scores: {
          precision_at5: 0.2,
          precision_at10: 0.1,
          recall: 0.5,
          mrr: 1.0,
          context_completeness: 0.5,
          token_efficiency: 0.5
        },
        tokens_used: 300
      )
    ]
  end

  let(:aggregates) do
    {
      mean_precision_at5: 0.3,
      mean_precision_at10: 0.15,
      mean_recall: 0.75,
      mean_mrr: 1.0,
      mean_context_completeness: 0.75,
      mean_token_efficiency: 0.5833,
      total_queries: 2,
      mean_tokens_used: 400.0
    }
  end

  let(:report) do
    CodebaseIndex::Evaluation::Evaluator::EvaluationReport.new(
      results: query_results,
      aggregates: aggregates
    )
  end

  describe '#generate' do
    it 'returns valid JSON' do
      json = generator.generate(report)

      expect { JSON.parse(json) }.not_to raise_error
    end

    it 'includes metadata section' do
      json = generator.generate(report)
      data = JSON.parse(json)

      expect(data).to have_key('metadata')
      expect(data['metadata']).to have_key('generated_at')
      expect(data['metadata']).to have_key('version')
    end

    it 'includes aggregates section' do
      json = generator.generate(report)
      data = JSON.parse(json)

      expect(data).to have_key('aggregates')
      expect(data['aggregates']['mean_recall']).to eq(0.75)
      expect(data['aggregates']['total_queries']).to eq(2)
    end

    it 'includes per-query results' do
      json = generator.generate(report)
      data = JSON.parse(json)

      expect(data['results'].size).to eq(2)
      expect(data['results'].first['query']).to eq('How does User model work?')
    end

    it 'serializes scores with string keys' do
      json = generator.generate(report)
      data = JSON.parse(json)

      scores = data['results'].first['scores']
      expect(scores).to have_key('recall')
      expect(scores).to have_key('mrr')
    end

    it 'rounds float values to 4 decimal places' do
      json = generator.generate(report)
      data = JSON.parse(json)

      expect(data['aggregates']['mean_token_efficiency']).to eq(0.5833)
    end

    it 'includes custom metadata' do
      json = generator.generate(report, metadata: { query_set: 'test.json' })
      data = JSON.parse(json)

      expect(data['metadata']['query_set']).to eq('test.json')
    end
  end

  describe '#save' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:output_path) { File.join(tmpdir, 'report.json') }

    after { FileUtils.remove_entry(tmpdir) }

    it 'writes the report to a file' do
      generator.save(report, output_path)

      expect(File.exist?(output_path)).to be true
    end

    it 'writes valid JSON to the file' do
      generator.save(report, output_path)

      data = JSON.parse(File.read(output_path))
      expect(data['aggregates']['total_queries']).to eq(2)
    end

    it 'creates parent directories if needed' do
      nested_path = File.join(tmpdir, 'nested', 'dir', 'report.json')

      generator.save(report, nested_path)

      expect(File.exist?(nested_path)).to be true
    end

    it 'includes metadata in saved file' do
      generator.save(report, output_path, metadata: { run_id: 'abc123' })

      data = JSON.parse(File.read(output_path))
      expect(data['metadata']['run_id']).to eq('abc123')
    end
  end
end
