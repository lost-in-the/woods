# frozen_string_literal: true

require 'spec_helper'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/storage/graph_store'
require 'woods/retriever'
require 'woods/formatting/human_adapter'

RSpec.describe 'Retrieval + Formatting Integration', :integration do
  # ── Fake Embedding Provider ──────────────────────────────────────

  let(:dimensions) { 8 }

  let(:embedding_provider) do
    dims = dimensions
    Class.new do
      include Woods::Embedding::Provider::Interface

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

  let(:vector_store) { Woods::Storage::VectorStore::InMemory.new }
  let(:metadata_store) { Woods::Storage::MetadataStore::SQLite.new(database: ':memory:') }
  let(:graph_store) { Woods::Storage::GraphStore::Memory.new }

  # ── Fixture Data ─────────────────────────────────────────────────

  let(:units) do
    [
      build_unit(
        type: :model, identifier: 'User', file_path: 'app/models/user.rb',
        source_code: "class User < ApplicationRecord\n  has_many :posts\n  validates :email, presence: true\nend",
        metadata: { associations: %w[posts], importance: 'high' },
        dependencies: [{ target: 'Post', type: :model, via: :association }]
      ),
      build_unit(
        type: :model, identifier: 'Post', file_path: 'app/models/post.rb',
        source_code: "class Post < ApplicationRecord\n  belongs_to :user\n  has_many :comments\nend",
        metadata: { associations: %w[user comments], importance: 'high' },
        dependencies: [{ target: 'User', type: :model, via: :association }]
      ),
      build_unit(
        type: :controller, identifier: 'PostsController', file_path: 'app/controllers/posts_controller.rb',
        source_code: "class PostsController < ApplicationController\n  def index\n    @posts = Post.all\n  end\nend",
        metadata: { actions: %w[index], importance: 'medium' },
        dependencies: [{ target: 'Post', type: :model, via: :reference }]
      )
    ]
  end

  before do
    populate_stores(units)
  end

  # ── Retriever ────────────────────────────────────────────────────

  let(:retriever) do
    Woods::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider
    )
  end

  # ── Retrieval Result ─────────────────────────────────────────────

  let(:retrieval_result) { retriever.retrieve('How does the User model work?') }

  # Build an AssembledContext from retrieval result for formatting
  let(:assembled_context) do
    Woods::Retrieval::AssembledContext.new(
      context: retrieval_result.context,
      tokens_used: retrieval_result.tokens_used,
      budget: retrieval_result.budget,
      sources: retrieval_result.sources,
      sections: %i[structural primary]
    )
  end

  # ── HumanAdapter ─────────────────────────────────────────────────

  describe Woods::Formatting::HumanAdapter do
    let(:adapter) { described_class.new }

    it 'produces box-drawing formatted output' do
      output = adapter.format(assembled_context)

      # Box-drawing characters
      expect(output).to include("\u2554") # top-left corner
      expect(output).to include("\u2557") # top-right corner
      expect(output).to include('Codebase Context')
    end

    it 'includes token usage summary' do
      output = adapter.format(assembled_context)

      expect(output).to include("Tokens: #{assembled_context.tokens_used} / #{assembled_context.budget}")
    end

    it 'includes Sources heading' do
      output = adapter.format(assembled_context)

      expect(output).to include('Sources:')
    end

    it 'includes source entries with box-drawing decorators' do
      output = adapter.format(assembled_context)

      assembled_context.sources.each do |source|
        expect(output).to include(source[:identifier].to_s)
      end
    end
  end

  # ── Retriever with formatter integration ─────────────────────────

  describe 'Retriever with formatter callback' do
    it 'applies a formatter to the context' do
      formatted_retriever = Woods::Retriever.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider,
        formatter: ->(ctx) { "<wrapped>#{ctx}</wrapped>" }
      )

      result = formatted_retriever.retrieve('How does the User model work?')
      expect(result.context).to start_with('<wrapped>')
      expect(result.context).to end_with('</wrapped>')
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  def build_unit(type:, identifier:, file_path:, source_code:, metadata: {}, dependencies: [])
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file_path)
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
end
