# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/extracted_unit'
require 'codebase_index/dependency_graph'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/storage/graph_store'
require 'codebase_index/retriever'
require 'codebase_index/mcp/server'
require 'codebase_index/flow_assembler'

RSpec.describe 'MCP Retrieval Tools Integration', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }

  # ── Fake Embedding Provider ──────────────────────────────────────

  let(:dimensions) { 8 }

  let(:embedding_provider) do
    dims = dimensions
    Class.new do
      include CodebaseIndex::Embedding::Provider::Interface

      define_method(:dimensions) { dims }
      define_method(:model_name) { 'fake-test' }

      define_method(:embed) do |text|
        bytes = Digest::SHA256.digest(text.to_s).bytes
        vec = Array.new(dims) { |i| bytes[i % bytes.size].to_f / 255.0 }
        magnitude = Math.sqrt(vec.sum { |v| v**2 })
        magnitude.zero? ? vec : vec.map { |v| v / magnitude }
      end

      define_method(:embed_batch) do |texts|
        texts.map { |t| embed(t) }
      end
    end.new
  end

  # ── Store Setup ──────────────────────────────────────────────────

  let(:vector_store) { CodebaseIndex::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { CodebaseIndex::Storage::MetadataStore::SQLite.new(':memory:') }
  let(:graph_store) { CodebaseIndex::Storage::GraphStore::Memory.new }

  # ── Fixture Data ─────────────────────────────────────────────────

  let(:units) do
    [
      build_unit(
        type: :model, identifier: 'User', file_path: 'app/models/user.rb',
        source_code: "class User < ApplicationRecord\n  has_many :posts\nend",
        metadata: { associations: %w[posts], importance: 'high' },
        dependencies: [{ target: 'Post', type: :model, via: :association }]
      ),
      build_unit(
        type: :model, identifier: 'Post', file_path: 'app/models/post.rb',
        source_code: "class Post < ApplicationRecord\n  belongs_to :user\n  has_many :comments\nend",
        metadata: { associations: %w[user comments], importance: 'high' },
        dependencies: [
          { target: 'User', type: :model, via: :association },
          { target: 'Comment', type: :model, via: :association }
        ]
      ),
      build_unit(
        type: :model, identifier: 'Comment', file_path: 'app/models/comment.rb',
        source_code: "class Comment < ApplicationRecord\n  belongs_to :post\nend",
        metadata: { associations: %w[post], importance: 'medium' },
        dependencies: [{ target: 'Post', type: :model, via: :association }]
      ),
      build_unit(
        type: :controller, identifier: 'PostsController', file_path: 'app/controllers/posts_controller.rb',
        source_code: "class PostsController < ApplicationController\n  " \
                     "def create\n    @post = Post.new(post_params)\n  end\nend",
        metadata: { actions: %w[create], importance: 'medium' },
        dependencies: [{ target: 'Post', type: :model, via: :reference }]
      )
    ]
  end

  before do
    populate_stores(units)
  end

  # ── Retriever ────────────────────────────────────────────────────

  let(:retriever) do
    CodebaseIndex::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider
    )
  end

  # ── MCP Server with real retriever ───────────────────────────────

  let(:server) do
    CodebaseIndex::MCP::Server.build(
      index_dir: fixture_dir,
      retriever: retriever
    )
  end

  # ── codebase_retrieve tool ───────────────────────────────────────

  describe 'tool: codebase_retrieve' do
    it 'returns context for a natural language query' do
      response = call_tool(server, 'codebase_retrieve', query: 'How does the User model work?')
      text = response_text(response)

      expect(text).not_to be_empty
      expect(text).to be_a(String)
    end

    it 'returns context containing relevant units' do
      response = call_tool(server, 'codebase_retrieve', query: 'How does the User model work?')
      text = response_text(response)

      expect(text).to include('User')
    end

    it 'includes structural context overview' do
      response = call_tool(server, 'codebase_retrieve', query: 'How does the User model work?')
      text = response_text(response)

      # Structural context is "Codebase: N units (X models, ...)"
      expect(text).to include('Codebase:')
    end

    it 'respects a custom budget parameter' do
      # Small budget should produce shorter context
      small_response = call_tool(server, 'codebase_retrieve', query: 'User model', budget: 200)
      large_response = call_tool(server, 'codebase_retrieve', query: 'User model', budget: 8000)

      small_text = response_text(small_response)
      large_text = response_text(large_response)

      expect(small_text.length).to be <= large_text.length
    end

    it 'uses default budget of 8000 when not specified' do
      # Just verify it works without a budget param
      response = call_tool(server, 'codebase_retrieve', query: 'Show me the Post model')
      text = response_text(response)

      expect(text).not_to be_empty
    end

    it 'handles queries about controllers' do
      response = call_tool(server, 'codebase_retrieve', query: 'Where is the PostsController?')
      text = response_text(response)

      expect(text).not_to be_empty
    end

    it 'handles trace queries' do
      response = call_tool(server, 'codebase_retrieve', query: 'What depends on the Post model?')
      text = response_text(response)

      expect(text).not_to be_empty
    end

    it 'handles exploratory queries' do
      response = call_tool(server, 'codebase_retrieve', query: 'Show me everything related to users')
      text = response_text(response)

      expect(text).not_to be_empty
    end
  end

  # ── trace_flow tool ──────────────────────────────────────────────

  describe 'tool: trace_flow' do
    let(:mock_flow_doc) do
      instance_double(
        'CodebaseIndex::FlowDocument',
        to_h: {
          entry_point: 'PostsController#create',
          route: { verb: 'POST', path: '/posts' },
          max_depth: 3,
          generated_at: '2026-02-18T00:00:00Z',
          steps: [
            { depth: 0, identifier: 'PostsController#create', type: 'controller_action' }
          ]
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

    it 'includes step information in the flow' do
      response = call_tool(server, 'trace_flow', entry_point: 'PostsController#create')
      data = parse_response(response)

      expect(data['steps']).to be_an(Array)
      expect(data['steps'].first['identifier']).to eq('PostsController#create')
    end

    it 'passes custom depth to the assembler' do
      call_tool(server, 'trace_flow', entry_point: 'PostsController#create', depth: 5)
      expect(mock_assembler).to have_received(:assemble).with('PostsController#create', max_depth: 5)
    end

    it 'uses default depth of 3 when not specified' do
      call_tool(server, 'trace_flow', entry_point: 'PostsController#create')
      expect(mock_assembler).to have_received(:assemble).with('PostsController#create', max_depth: 3)
    end

    it 'returns an error when assembly fails' do
      allow(mock_assembler).to receive(:assemble).and_raise(StandardError, 'unit not found')

      response = call_tool(server, 'trace_flow', entry_point: 'Unknown#action')
      data = parse_response(response)

      expect(data['error']).to eq('unit not found')
    end
  end

  # ── Both tools working together ──────────────────────────────────

  describe 'retrieve then trace workflow' do
    let(:mock_flow_doc) do
      instance_double(
        'CodebaseIndex::FlowDocument',
        to_h: {
          entry_point: 'PostsController#create',
          route: { verb: 'POST', path: '/posts' },
          max_depth: 3,
          generated_at: '2026-02-18T00:00:00Z',
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

    it 'can retrieve context then trace a flow from the same server' do
      # Step 1: Retrieve context about Post
      retrieve_response = call_tool(server, 'codebase_retrieve', query: 'Post model')
      retrieve_text = response_text(retrieve_response)
      expect(retrieve_text).not_to be_empty

      # Step 2: Trace flow from PostsController#create
      trace_response = call_tool(server, 'trace_flow', entry_point: 'PostsController#create')
      trace_data = parse_response(trace_response)
      expect(trace_data['entry_point']).to eq('PostsController#create')
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  def build_unit(type:, identifier:, file_path:, source_code:, metadata: {}, dependencies: [])
    unit = CodebaseIndex::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
    unit.source_code = source_code
    unit.metadata = metadata
    unit.dependencies = dependencies
    unit
  end

  def populate_stores(units)
    units.each do |unit|
      metadata_store.store(unit.identifier, {
                             type: unit.type.to_s,
                             identifier: unit.identifier,
                             file_path: unit.file_path,
                             namespace: unit.namespace,
                             source_code: unit.source_code,
                             metadata: unit.metadata,
                             dependencies: unit.dependencies
                           })

      vector = embedding_provider.embed(unit.source_code)
      vector_store.store(unit.identifier, vector, { type: unit.type.to_s })

      graph_store.register(unit)
    end
  end

  # MCP tool call helpers — same pattern as server_spec.rb
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
