# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/server'

RSpec.describe CodebaseIndex::MCP::Server do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:server) { described_class.build(index_dir: fixture_dir) }

  describe '.build' do
    it 'returns an MCP::Server' do
      expect(server).to be_a(MCP::Server)
    end

    it 'registers 21 tools' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.size).to eq(21)
    end

    it 'registers expected tool names' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).to contain_exactly(
        'lookup', 'search', 'dependencies', 'dependents',
        'structure', 'graph_analysis', 'pagerank', 'framework',
        'recent_changes', 'reload', 'codebase_retrieve',
        'trace_flow',
        'pipeline_extract', 'pipeline_embed', 'pipeline_status',
        'pipeline_diagnose', 'pipeline_repair',
        'retrieval_rate', 'retrieval_report_gap',
        'retrieval_explain', 'retrieval_suggest'
      )
    end

    it 'registers 2 resources' do
      resources = server.instance_variable_get(:@resources)
      expect(resources.size).to eq(2)
    end

    it 'registers expected resource URIs' do
      resources = server.instance_variable_get(:@resources)
      uris = resources.map(&:uri)
      expect(uris).to contain_exactly('codebase://manifest', 'codebase://graph')
    end

    it 'registers 2 resource templates' do
      templates = server.instance_variable_get(:@resource_templates)
      expect(templates.size).to eq(2)
    end

    it 'registers expected resource template URIs' do
      templates = server.instance_variable_get(:@resource_templates)
      uris = templates.map(&:uri_template)
      expect(uris).to contain_exactly('codebase://unit/{identifier}', 'codebase://type/{type}')
    end
  end

  describe 'tool: lookup' do
    it 'returns unit data for a valid identifier' do
      response = call_tool(server, 'lookup', identifier: 'Post')
      data = parse_response(response)
      expect(data['identifier']).to eq('Post')
      expect(data['type']).to eq('model')
      expect(data['source_code']).to include('has_many')
    end

    it 'returns not found message for invalid identifier' do
      response = call_tool(server, 'lookup', identifier: 'NonExistent')
      expect(response_text(response)).to include('not found')
    end

    it 'excludes source_code when include_source is false' do
      response = call_tool(server, 'lookup', identifier: 'Post', include_source: false)
      data = parse_response(response)
      expect(data['identifier']).to eq('Post')
      expect(data).not_to have_key('source_code')
      expect(data['metadata']).to be_a(Hash)
    end

    it 'returns only selected sections plus always-included keys' do
      response = call_tool(server, 'lookup', identifier: 'Post', sections: ['metadata'])
      data = parse_response(response)
      expect(data.keys).to contain_exactly('type', 'identifier', 'file_path', 'namespace', 'metadata')
    end

    it 'returns full data by default for backward compatibility' do
      response = call_tool(server, 'lookup', identifier: 'Post')
      data = parse_response(response)
      expect(data).to have_key('source_code')
      expect(data).to have_key('metadata')
      expect(data).to have_key('dependencies')
    end

    it 'treats empty sections array as no filtering' do
      response = call_tool(server, 'lookup', identifier: 'Post', sections: [])
      data = parse_response(response)
      expect(data).to have_key('source_code')
      expect(data).to have_key('metadata')
      expect(data).to have_key('dependencies')
    end
  end

  describe 'tool: search' do
    it 'returns matching results' do
      response = call_tool(server, 'search', query: 'Post')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('Post')
    end

    it 'filters by type' do
      response = call_tool(server, 'search', query: 'Post', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end

    it 'respects limit' do
      response = call_tool(server, 'search', query: 'o', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end
  end

  describe 'tool: dependencies' do
    it 'returns forward dependencies' do
      response = call_tool(server, 'dependencies', identifier: 'Comment')
      data = parse_response(response)
      expect(data['root']).to eq('Comment')
      expect(data['nodes']['Comment']['deps']).to include('Post')
    end

    it 'returns empty for unknown identifier' do
      response = call_tool(server, 'dependencies', identifier: 'NonExistent')
      data = parse_response(response)
      expect(data['nodes']).to be_empty
      expect(data['found']).to be false
    end

    it 'includes message for unknown identifier' do
      response = call_tool(server, 'dependencies', identifier: 'NonExistent')
      data = parse_response(response)
      expect(data['found']).to be false
      expect(data['message']).to include('not found in the index')
    end
  end

  describe 'tool: dependents' do
    it 'returns reverse dependencies' do
      response = call_tool(server, 'dependents', identifier: 'Post')
      data = parse_response(response)
      expect(data['root']).to eq('Post')
      expect(data['nodes']['Post']['deps']).to include('Comment', 'PostsController')
    end

    it 'returns found: true with no message for known identifier' do
      response = call_tool(server, 'dependents', identifier: 'Post')
      data = parse_response(response)
      expect(data['found']).to be true
      expect(data).not_to have_key('message')
    end
  end

  describe 'tool: structure' do
    it 'returns manifest by default' do
      response = call_tool(server, 'structure')
      data = parse_response(response)
      expect(data['manifest']).to include('rails_version' => '8.1.2')
    end

    it 'includes summary when detail is full' do
      response = call_tool(server, 'structure', detail: 'full')
      data = parse_response(response)
      expect(data['summary']).to include('Codebase Index Summary')
    end

    it 'excludes summary when detail is summary' do
      response = call_tool(server, 'structure', detail: 'summary')
      data = parse_response(response)
      expect(data).not_to have_key('summary')
    end
  end

  describe 'tool: graph_analysis' do
    it 'returns all sections by default' do
      response = call_tool(server, 'graph_analysis')
      data = parse_response(response)
      expect(data).to include('orphans', 'dead_ends', 'hubs', 'cycles')
    end

    it 'returns a specific section' do
      response = call_tool(server, 'graph_analysis', analysis: 'orphans')
      data = parse_response(response)
      expect(data).to have_key('orphans')
      expect(data['orphans']).to include('PostsController')
    end

    it 'truncates each section when analysis is all with limit' do
      response = call_tool(server, 'graph_analysis', analysis: 'all', limit: 1)
      data = parse_response(response)
      expect(data['hubs'].size).to eq(1)
      expect(data['hubs_total']).to eq(3)
      expect(data['hubs_truncated']).to be true
      # Sections with 1 or fewer items should not have truncation metadata
      expect(data['orphans'].size).to eq(1)
      expect(data).not_to have_key('orphans_truncated')
    end

    it 'truncates nested dependents in hub entries' do
      response = call_tool(server, 'graph_analysis', analysis: 'hubs', limit: 1)
      data = parse_response(response)
      hub = data['hubs'].first
      expect(hub['identifier']).to eq('Post')
      expect(hub['dependents'].size).to eq(1)
      expect(hub['dependents_truncated']).to be true
      expect(hub['dependents_total']).to eq(2)
    end

    it 'handles negative limit without crashing' do
      response = call_tool(server, 'graph_analysis', analysis: 'all', limit: -1)
      data = parse_response(response)
      expect(data['hubs']).to eq([])
      expect(data).to have_key('stats')
    end
  end

  describe 'tool: pagerank' do
    it 'returns ranked nodes with scores' do
      response = call_tool(server, 'pagerank')
      data = parse_response(response)
      expect(data['total_nodes']).to eq(3)
      expect(data['results']).to be_an(Array)
      expect(data['results'].first).to include('identifier', 'type', 'score')
    end

    it 'respects limit' do
      response = call_tool(server, 'pagerank', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end

    it 'filters by type' do
      response = call_tool(server, 'pagerank', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end
  end

  describe 'tool: reload' do
    it 'returns reloaded confirmation with manifest fields' do
      response = call_tool(server, 'reload')
      data = parse_response(response)
      expect(data['reloaded']).to be true
      expect(data).to have_key('extracted_at')
      expect(data).to have_key('total_units')
      expect(data).to have_key('counts')
    end

    it 'picks up changed data after reload' do
      # Read structure before reload
      pre = parse_response(call_tool(server, 'structure'))
      expect(pre['manifest']['total_units']).to eq(5)

      # Modify manifest on disk
      manifest_path = File.join(fixture_dir, 'manifest.json')
      original_content = File.read(manifest_path)
      modified = JSON.parse(original_content).merge('total_units' => 42)

      begin
        File.write(manifest_path, JSON.generate(modified))
        call_tool(server, 'reload')

        # Structure should now reflect the new value
        post = parse_response(call_tool(server, 'structure'))
        expect(post['manifest']['total_units']).to eq(42)
      ensure
        File.write(manifest_path, original_content)
      end
    end
  end

  describe 'tool: framework' do
    it 'returns matching rails_source units by identifier keyword' do
      response = call_tool(server, 'framework', keyword: 'ActiveRecord')
      data = parse_response(response)
      expect(data['keyword']).to eq('ActiveRecord')
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against source_code' do
      response = call_tool(server, 'framework', keyword: 'Persistence')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against metadata' do
      response = call_tool(server, 'framework', keyword: 'controller')
      data = parse_response(response)
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActionController::Base')
    end

    it 'returns empty results for no match' do
      response = call_tool(server, 'framework', keyword: 'zzz_no_match')
      data = parse_response(response)
      expect(data['result_count']).to eq(0)
      expect(data['results']).to be_empty
    end

    it 'respects limit' do
      response = call_tool(server, 'framework', keyword: 'Base', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end
  end

  describe 'tool: recent_changes' do
    it 'returns units sorted by last_modified descending' do
      response = call_tool(server, 'recent_changes')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      dates = data['results'].map { |r| r['last_modified'] }
      expect(dates).to eq(dates.sort.reverse)
    end

    it 'returns the most recently modified unit first' do
      response = call_tool(server, 'recent_changes')
      data = parse_response(response)
      expect(data['results'].first['identifier']).to eq('Comment')
    end

    it 'respects limit' do
      response = call_tool(server, 'recent_changes', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end

    it 'filters by type' do
      response = call_tool(server, 'recent_changes', types: ['controller'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('controller')
      end
    end
  end

  describe 'tool: codebase_retrieve' do
    context 'without retriever configured' do
      it 'returns a fallback message' do
        response = call_tool(server, 'codebase_retrieve', query: 'How does authentication work?')
        text = response_text(response)
        expect(text).to include('Semantic search is not available')
        expect(text).to include('search')
      end
    end

    context 'with retriever configured' do
      let(:mock_result) do
        Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget, keyword_init: true).new(
          context: "## User (model)\nclass User < ApplicationRecord\nend",
          sources: [{ identifier: 'User', type: 'model' }],
          classification: nil,
          strategy: :vector,
          tokens_used: 150,
          budget: 8000
        )
      end

      let(:retriever) do
        instance_double('CodebaseIndex::Retriever').tap do |r|
          allow(r).to receive(:retrieve).and_return(mock_result)
        end
      end

      let(:server_with_retriever) do
        described_class.build(index_dir: fixture_dir, retriever: retriever)
      end

      it 'calls the retriever with the query and default budget' do
        call_tool(server_with_retriever, 'codebase_retrieve', query: 'How does the User model work?')
        expect(retriever).to have_received(:retrieve).with('How does the User model work?', budget: 8000)
      end

      it 'passes a custom budget to the retriever' do
        call_tool(server_with_retriever, 'codebase_retrieve', query: 'User model', budget: 4000)
        expect(retriever).to have_received(:retrieve).with('User model', budget: 4000)
      end

      it 'returns the context from the retrieval result' do
        response = call_tool(server_with_retriever, 'codebase_retrieve', query: 'User model')
        text = response_text(response)
        expect(text).to include('User (model)')
        expect(text).to include('ApplicationRecord')
      end
    end
  end

  # ── Operator tools ──────────────────────────────────────────────

  describe 'tool: pipeline_status' do
    context 'without operator configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'pipeline_status')
        expect(response_text(response)).to include('not configured')
      end
    end

    context 'with operator configured' do
      let(:status_reporter) do
        instance_double('CodebaseIndex::Operator::StatusReporter').tap do |r|
          allow(r).to receive(:report).and_return({
                                                    status: :ok,
                                                    extracted_at: '2026-02-15T10:00:00Z',
                                                    total_units: 42,
                                                    counts: { 'models' => 10 },
                                                    git_sha: 'abc123',
                                                    git_branch: 'main',
                                                    staleness_seconds: 3600
                                                  })
        end
      end

      let(:operator) { { status_reporter: status_reporter } }

      let(:server_with_operator) do
        described_class.build(index_dir: fixture_dir, operator: operator)
      end

      it 'returns pipeline status' do
        response = call_tool(server_with_operator, 'pipeline_status')
        data = parse_response(response)
        expect(data['status']).to eq('ok')
        expect(data['total_units']).to eq(42)
      end
    end
  end

  describe 'tool: pipeline_extract' do
    context 'without operator configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'pipeline_extract')
        expect(response_text(response)).to include('not configured')
      end
    end

    context 'with operator configured' do
      let(:guard) do
        instance_double('CodebaseIndex::Operator::PipelineGuard').tap do |g|
          allow(g).to receive(:allow?).with(:extraction).and_return(true)
          allow(g).to receive(:record!).with(:extraction)
        end
      end

      let(:operator) { { pipeline_guard: guard } }

      let(:server_with_operator) do
        described_class.build(index_dir: fixture_dir, operator: operator)
      end

      it 'returns started status and spawns a background thread' do
        response = call_tool(server_with_operator, 'pipeline_extract')
        data = parse_response(response)
        expect(data['status']).to eq('started')
        expect(data['message']).to include('background thread')
        # Allow background thread to attempt execution and rescue
        sleep 0.05
      end

      it 'is rate-limited when guard denies' do
        allow(guard).to receive(:allow?).with(:extraction).and_return(false)
        response = call_tool(server_with_operator, 'pipeline_extract')
        expect(response_text(response)).to include('rate-limited')
      end
    end
  end

  describe 'tool: pipeline_embed' do
    context 'without operator configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'pipeline_embed')
        expect(response_text(response)).to include('not configured')
      end
    end

    context 'with operator configured' do
      let(:guard) do
        instance_double('CodebaseIndex::Operator::PipelineGuard').tap do |g|
          allow(g).to receive(:allow?).with(:embedding).and_return(true)
          allow(g).to receive(:record!).with(:embedding)
        end
      end

      let(:operator) { { pipeline_guard: guard } }

      let(:server_with_operator) do
        described_class.build(index_dir: fixture_dir, operator: operator)
      end

      it 'returns started status and spawns a background thread' do
        response = call_tool(server_with_operator, 'pipeline_embed')
        data = parse_response(response)
        expect(data['status']).to eq('started')
        expect(data['message']).to include('background thread')
        sleep 0.05
      end

      it 'is rate-limited when guard denies' do
        allow(guard).to receive(:allow?).with(:embedding).and_return(false)
        response = call_tool(server_with_operator, 'pipeline_embed')
        expect(response_text(response)).to include('rate-limited')
      end
    end
  end

  describe 'tool: pipeline_extract incremental param' do
    let(:guard) do
      instance_double('CodebaseIndex::Operator::PipelineGuard').tap do |g|
        allow(g).to receive(:allow?).with(:extraction).and_return(true)
        allow(g).to receive(:record!).with(:extraction)
      end
    end

    let(:operator) { { pipeline_guard: guard } }

    let(:server_with_operator) do
      described_class.build(index_dir: fixture_dir, operator: operator)
    end

    let(:mock_extractor) do
      double('Extractor').tap do |e|
        allow(e).to receive(:extract_all)
        allow(e).to receive(:extract_changed)
      end
    end

    let(:extractor_class) { double('ExtractorClass', new: mock_extractor) }

    before do
      stub_const('CodebaseIndex::Extractor', extractor_class)
      mock_config = Struct.new(:output_dir).new(fixture_dir)
      CodebaseIndex.configuration = mock_config
    end

    after do
      CodebaseIndex.configuration = nil
    end

    it 'calls extract_changed when incremental is true' do
      call_tool(server_with_operator, 'pipeline_extract', incremental: true)
      sleep 0.2
      expect(mock_extractor).to have_received(:extract_changed).with([])
    end

    it 'calls extract_all when incremental is false' do
      call_tool(server_with_operator, 'pipeline_extract', incremental: false)
      sleep 0.2
      expect(mock_extractor).to have_received(:extract_all)
    end
  end

  describe 'tool: pipeline_embed incremental param' do
    let(:guard) do
      instance_double('CodebaseIndex::Operator::PipelineGuard').tap do |g|
        allow(g).to receive(:allow?).with(:embedding).and_return(true)
        allow(g).to receive(:record!).with(:embedding)
      end
    end

    let(:operator) { { pipeline_guard: guard } }

    let(:server_with_operator) do
      described_class.build(index_dir: fixture_dir, operator: operator)
    end

    let(:mock_builder) do
      double('Builder').tap do |b|
        allow(b).to receive(:build_embedding_provider).and_return(double('provider'))
        allow(b).to receive(:build_vector_store).and_return(double('vector_store'))
      end
    end

    let(:mock_indexer) do
      double('Indexer').tap do |i|
        allow(i).to receive(:index_all)
        allow(i).to receive(:index_incremental)
      end
    end

    let(:text_preparer_class) { double('TextPreparerClass', new: double('text_preparer')) }
    let(:indexer_class) { double('IndexerClass', new: mock_indexer) }

    before do
      mock_config = Struct.new(:output_dir).new(fixture_dir)
      CodebaseIndex.configuration = mock_config
      allow(CodebaseIndex::Builder).to receive(:new).and_return(mock_builder)
      stub_const('CodebaseIndex::Embedding::TextPreparer', text_preparer_class)
      stub_const('CodebaseIndex::Embedding::Indexer', indexer_class)
    end

    after do
      CodebaseIndex.configuration = nil
    end

    it 'calls index_incremental when incremental is true' do
      call_tool(server_with_operator, 'pipeline_embed', incremental: true)
      sleep 0.2
      expect(mock_indexer).to have_received(:index_incremental)
    end

    it 'calls index_all when incremental is false' do
      call_tool(server_with_operator, 'pipeline_embed', incremental: false)
      sleep 0.2
      expect(mock_indexer).to have_received(:index_all)
    end
  end

  describe 'tool: trace_flow' do
    let(:mock_flow_doc) do
      instance_double(
        'CodebaseIndex::FlowDocument',
        to_h: {
          entry_point: 'PostsController#create',
          route: { verb: 'POST', path: '/posts' },
          max_depth: 3,
          generated_at: '2026-02-17T00:00:00Z',
          steps: []
        }
      )
    end

    let(:mock_assembler) do
      instance_double('CodebaseIndex::FlowAssembler').tap do |a|
        allow(a).to receive(:assemble).and_return(mock_flow_doc)
      end
    end

    before do
      allow(CodebaseIndex::FlowAssembler).to receive(:new).and_return(mock_assembler)
    end

    it 'returns a flow document for a valid entry point' do
      response = call_tool(server, 'trace_flow', entry_point: 'PostsController#create')
      data = parse_response(response)
      expect(data['entry_point']).to eq('PostsController#create')
      expect(data).to have_key('steps')
      expect(data).to have_key('route')
    end

    it 'passes entry_point and max_depth to the assembler' do
      call_tool(server, 'trace_flow', entry_point: 'PostsController#create', depth: 5)
      expect(mock_assembler).to have_received(:assemble).with('PostsController#create', max_depth: 5)
    end

    it 'uses default depth of 3 when not specified' do
      call_tool(server, 'trace_flow', entry_point: 'PostsController#index')
      expect(mock_assembler).to have_received(:assemble).with('PostsController#index', max_depth: 3)
    end

    it 'reuses the existing IndexReader instead of creating a new one' do
      # server is already built (which calls IndexReader.new once).
      # Verify that calling trace_flow does NOT create another IndexReader.
      server # force build
      expect(CodebaseIndex::MCP::IndexReader).not_to receive(:new)
      call_tool(server, 'trace_flow', entry_point: 'PostsController#create')
    end

    it 'returns an error hash when assembly raises' do
      allow(mock_assembler).to receive(:assemble).and_raise(StandardError, 'unit not found')
      response = call_tool(server, 'trace_flow', entry_point: 'Unknown#action')
      data = parse_response(response)
      expect(data['error']).to eq('unit not found')
    end
  end

  describe 'tool: pipeline_repair' do
    context 'without operator configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'pipeline_repair', action: 'clear_locks')
        expect(response_text(response)).to include('not configured')
      end
    end
  end

  # ── Feedback tools ─────────────────────────────────────────────

  describe 'tool: retrieval_rate' do
    context 'without feedback store configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'retrieval_rate', query: 'test', score: 4)
        expect(response_text(response)).to include('not configured')
      end
    end

    context 'with feedback store configured' do
      let(:feedback_store) do
        instance_double('CodebaseIndex::Feedback::Store').tap do |s|
          allow(s).to receive(:record_rating)
        end
      end

      let(:server_with_feedback) do
        described_class.build(index_dir: fixture_dir, feedback_store: feedback_store)
      end

      it 'records a rating and returns confirmation' do
        response = call_tool(server_with_feedback, 'retrieval_rate', query: 'User model', score: 4)
        data = parse_response(response)
        expect(data['recorded']).to be true
        expect(data['score']).to eq(4)
        expect(feedback_store).to have_received(:record_rating).with(query: 'User model', score: 4, comment: nil)
      end
    end
  end

  describe 'tool: retrieval_report_gap' do
    context 'without feedback store configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'retrieval_report_gap',
                             query: 'payments', missing_unit: 'PaymentService', unit_type: 'service')
        expect(response_text(response)).to include('not configured')
      end
    end
  end

  describe 'tool: retrieval_explain' do
    context 'without feedback store configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'retrieval_explain')
        expect(response_text(response)).to include('not configured')
      end
    end

    context 'with feedback store configured' do
      let(:feedback_store) do
        instance_double('CodebaseIndex::Feedback::Store').tap do |s|
          allow(s).to receive(:ratings).and_return([
                                                     { 'query' => 'test', 'score' => 4,
                                                       'timestamp' => '2026-02-15T10:00:00Z' }
                                                   ])
          allow(s).to receive(:gaps).and_return([])
          allow(s).to receive(:average_score).and_return(4.0)
        end
      end

      let(:server_with_feedback) do
        described_class.build(index_dir: fixture_dir, feedback_store: feedback_store)
      end

      it 'returns feedback statistics' do
        response = call_tool(server_with_feedback, 'retrieval_explain')
        data = parse_response(response)
        expect(data['total_ratings']).to eq(1)
        expect(data['average_score']).to eq(4.0)
        expect(data['total_gaps']).to eq(0)
      end
    end
  end

  describe 'tool: retrieval_suggest' do
    context 'without feedback store configured' do
      it 'returns not configured message' do
        response = call_tool(server, 'retrieval_suggest')
        expect(response_text(response)).to include('not configured')
      end
    end
  end

  describe 'resource template: codebase://unit/{identifier}' do
    it 'returns unit data for a valid identifier' do
      contents = read_resource(server, 'codebase://unit/Post')
      data = JSON.parse(contents.first[:text])
      expect(data['identifier']).to eq('Post')
      expect(data['type']).to eq('model')
    end

    it 'returns not found for an invalid identifier' do
      contents = read_resource(server, 'codebase://unit/NonExistent')
      expect(contents.first[:text]).to include('not found')
    end
  end

  describe 'resource template: codebase://type/{type}' do
    it 'returns all units of the given type' do
      contents = read_resource(server, 'codebase://type/model')
      data = JSON.parse(contents.first[:text])
      identifiers = data.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly('Post', 'Comment')
    end

    it 'returns empty array for unknown type' do
      contents = read_resource(server, 'codebase://type/nonexistent')
      data = JSON.parse(contents.first[:text])
      expect(data).to eq([])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────────────────────

  # Call a tool on the server by name with the given arguments.
  # MCP stores tools as Hash<String, Class>.
  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  # Extract the text content from a tool response.
  def response_text(response)
    response.content.first[:text]
  end

  # Parse JSON from a tool response.
  def parse_response(response)
    JSON.parse(response_text(response))
  end

  # Call the resources_read_handler on the server.
  def read_resource(server, uri)
    handler = server.instance_variable_get(:@handlers)
    read_handler = handler[MCP::Methods::RESOURCES_READ]
    read_handler.call(uri: uri)
  end
end
