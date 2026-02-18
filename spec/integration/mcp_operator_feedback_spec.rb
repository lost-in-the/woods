# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/mcp/server'
require 'codebase_index/operator/pipeline_guard'
require 'codebase_index/operator/status_reporter'
require 'codebase_index/feedback/store'
require 'codebase_index/feedback/gap_detector'
require 'tmpdir'
require 'json'

RSpec.describe 'MCP Operator + Feedback Tools Integration', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:tmpdir) { Dir.mktmpdir('mcp_operator_test') }

  after { FileUtils.rm_rf(tmpdir) }

  # ── Real PipelineGuard ──────────────────────────────────────────

  let(:guard) do
    CodebaseIndex::Operator::PipelineGuard.new(state_dir: tmpdir, cooldown: 60)
  end

  # ── Real StatusReporter ─────────────────────────────────────────

  let(:status_reporter) do
    CodebaseIndex::Operator::StatusReporter.new(output_dir: fixture_dir)
  end

  # ── Real FeedbackStore ──────────────────────────────────────────

  let(:feedback_path) { File.join(tmpdir, 'feedback.jsonl') }
  let(:feedback_store) { CodebaseIndex::Feedback::Store.new(path: feedback_path) }

  # ── MCP Server ──────────────────────────────────────────────────

  let(:operator) { { pipeline_guard: guard, status_reporter: status_reporter } }

  let(:server) do
    CodebaseIndex::MCP::Server.build(
      index_dir: fixture_dir,
      operator: operator,
      feedback_store: feedback_store
    )
  end

  # ── pipeline_status tool ────────────────────────────────────────

  describe 'tool: pipeline_status' do
    it 'returns status from real StatusReporter' do
      response = call_tool(server, 'pipeline_status')
      data = parse_response(response)

      expect(data).to have_key('status')
      expect(data).to have_key('extracted_at')
      expect(data).to have_key('total_units')
      expect(data).to have_key('counts')
    end

    it 'reports correct total_units from fixture manifest' do
      response = call_tool(server, 'pipeline_status')
      data = parse_response(response)

      expect(data['total_units']).to eq(5)
    end
  end

  # ── pipeline_extract tool with guard ────────────────────────────

  describe 'tool: pipeline_extract' do
    it 'allows first extraction (guard has no prior runs)' do
      response = call_tool(server, 'pipeline_extract')
      data = parse_response(response)

      expect(data['status']).to eq('started')
      # Allow background thread to run and rescue
      sleep 0.05
    end

    it 'blocks extraction within cooldown period' do
      # Record a recent extraction run
      guard.record!(:extraction)

      response = call_tool(server, 'pipeline_extract')
      text = response_text(response)

      expect(text).to include('rate-limited')
    end

    it 'allows extraction after cooldown expires' do
      guard.record!(:extraction)

      # Advance time past the 60-second cooldown instead of sleeping
      allow(Time).to receive(:now).and_return(Time.now + 61)

      response = call_tool(server, 'pipeline_extract')
      data = parse_response(response)

      expect(data['status']).to eq('started')
      sleep 0.05
    end
  end

  # ── pipeline_embed tool with guard ──────────────────────────────

  describe 'tool: pipeline_embed' do
    it 'allows first embedding (guard has no prior runs)' do
      response = call_tool(server, 'pipeline_embed')
      data = parse_response(response)

      expect(data['status']).to eq('started')
      sleep 0.05
    end

    it 'blocks embedding within cooldown period' do
      guard.record!(:embedding)

      response = call_tool(server, 'pipeline_embed')
      text = response_text(response)

      expect(text).to include('rate-limited')
    end
  end

  # ── retrieval_rate tool ─────────────────────────────────────────

  describe 'tool: retrieval_rate' do
    it 'records a rating to the real feedback store' do
      response = call_tool(server, 'retrieval_rate', query: 'User model', score: 4)
      data = parse_response(response)

      expect(data['recorded']).to be true
      expect(data['score']).to eq(4)

      # Verify it was persisted
      ratings = feedback_store.ratings
      expect(ratings.size).to eq(1)
      expect(ratings.first['query']).to eq('User model')
      expect(ratings.first['score']).to eq(4)
    end

    it 'records multiple ratings' do
      call_tool(server, 'retrieval_rate', query: 'User model', score: 5)
      call_tool(server, 'retrieval_rate', query: 'Post model', score: 3)

      expect(feedback_store.ratings.size).to eq(2)
      expect(feedback_store.average_score).to eq(4.0)
    end
  end

  # ── retrieval_report_gap tool ───────────────────────────────────

  describe 'tool: retrieval_report_gap' do
    it 'records a gap to the real feedback store' do
      response = call_tool(server, 'retrieval_report_gap',
                           query: 'payments', missing_unit: 'PaymentService', unit_type: 'service')
      data = parse_response(response)

      expect(data['recorded']).to be true
      expect(data['missing_unit']).to eq('PaymentService')

      gaps = feedback_store.gaps
      expect(gaps.size).to eq(1)
      expect(gaps.first['missing_unit']).to eq('PaymentService')
    end
  end

  # ── retrieval_explain tool ──────────────────────────────────────

  describe 'tool: retrieval_explain' do
    it 'returns statistics from real feedback data' do
      # Seed some feedback
      feedback_store.record_rating(query: 'User model', score: 4)
      feedback_store.record_rating(query: 'Post model', score: 2)
      feedback_store.record_gap(query: 'payments', missing_unit: 'PaymentService', unit_type: 'service')

      response = call_tool(server, 'retrieval_explain')
      data = parse_response(response)

      expect(data['total_ratings']).to eq(2)
      expect(data['average_score']).to eq(3.0)
      expect(data['total_gaps']).to eq(1)
    end
  end

  # ── retrieval_suggest tool ──────────────────────────────────────

  describe 'tool: retrieval_suggest' do
    it 'detects patterns in low-score feedback' do
      # Seed enough low-score feedback to trigger pattern detection
      feedback_store.record_rating(query: 'payment processing flow', score: 1)
      feedback_store.record_rating(query: 'payment gateway integration', score: 2)
      feedback_store.record_gap(query: 'payments', missing_unit: 'PaymentService', unit_type: 'service')
      feedback_store.record_gap(query: 'billing', missing_unit: 'PaymentService', unit_type: 'service')

      response = call_tool(server, 'retrieval_suggest')
      data = parse_response(response)

      expect(data).to have_key('issues_found')
      expect(data['issues_found']).to be >= 1

      # Should detect "payment" as a repeated low-score keyword
      patterns = data['issues'].select { |i| i['type'] == 'repeated_low_scores' }
      keywords = patterns.map { |p| p['pattern'] }
      expect(keywords).to include('payment')

      # Should detect PaymentService as frequently missing
      missing = data['issues'].select { |i| i['type'] == 'frequently_missing' }
      units = missing.map { |m| m['unit'] }
      expect(units).to include('PaymentService')
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  def parse_response(response)
    JSON.parse(response_text(response))
  end
end
