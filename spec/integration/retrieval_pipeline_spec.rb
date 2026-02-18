# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extracted_unit'
require 'codebase_index/dependency_graph'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/storage/graph_store'
require 'codebase_index/retriever'

RSpec.describe 'Retrieval Pipeline Integration', :integration do
  # ── Fake Embedding Provider ──────────────────────────────────────
  # Deterministic embeddings: hash the text into a fixed-dimension vector.
  # Same text always produces the same vector, enabling repeatable similarity scores.

  let(:dimensions) { 8 }

  let(:embedding_provider) do
    dims = dimensions
    Class.new do
      include CodebaseIndex::Embedding::Provider::Interface

      define_method(:dimensions) { dims }
      define_method(:model_name) { 'fake-test' }

      define_method(:embed) do |text|
        # Deterministic hash-based vector: spread bytes across dimensions
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
        source_code: "class User < ApplicationRecord\n  has_many :posts\n  has_many :comments\nend",
        metadata: { associations: %w[posts comments], importance: 'high' },
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
        source_code: "class Comment < ApplicationRecord\n  belongs_to :post\n  belongs_to :user\nend",
        metadata: { associations: %w[post user], importance: 'medium' },
        dependencies: [
          { target: 'Post', type: :model, via: :association },
          { target: 'User', type: :model, via: :association }
        ]
      ),
      build_unit(
        type: :controller, identifier: 'PostsController', file_path: 'app/controllers/posts_controller.rb',
        source_code: "class PostsController < ApplicationController\n  def index\n    @posts = Post.all\n  end\nend",
        metadata: { actions: %w[index], importance: 'medium' },
        dependencies: [{ target: 'Post', type: :model, via: :reference }]
      ),
      build_unit(
        type: :service, identifier: 'UserRegistration', file_path: 'app/services/user_registration.rb',
        source_code: "class UserRegistration\n  def call(params)\n    User.create!(params)\n  end\nend",
        metadata: { importance: 'medium' },
        dependencies: [{ target: 'User', type: :model, via: :reference }]
      ),
      build_unit(
        type: :job, identifier: 'NotificationJob', file_path: 'app/jobs/notification_job.rb',
        source_code: "class NotificationJob < ApplicationJob\n  " \
                     "def perform(user_id)\n    user = User.find(user_id)\n  end\nend",
        metadata: { importance: 'low' },
        dependencies: [{ target: 'User', type: :model, via: :reference }]
      )
    ]
  end

  before do
    populate_stores(units)
  end

  # ── Retriever Setup ──────────────────────────────────────────────

  let(:retriever) do
    CodebaseIndex::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider
    )
  end

  # ── Tests ────────────────────────────────────────────────────────

  describe 'full retrieval pipeline' do
    it 'returns a RetrievalResult for a model query' do
      result = retriever.retrieve('How does the User model work?')

      expect(result).to be_a(CodebaseIndex::Retriever::RetrievalResult)
      expect(result.context).to be_a(String)
      expect(result.context).not_to be_empty
      expect(result.sources).to be_an(Array)
      expect(result.strategy).to be_a(Symbol)
      expect(result.tokens_used).to be_a(Integer)
      expect(result.tokens_used).to be_positive
      expect(result.budget).to eq(8000)
    end

    it 'includes a retrieval trace' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.trace).to be_a(CodebaseIndex::Retriever::RetrievalTrace)
      expect(result.trace.candidate_count).to be_positive
      expect(result.trace.ranked_count).to be_positive
      expect(result.trace.elapsed_ms).to be_a(Numeric)
      expect(result.trace.elapsed_ms).to be >= 0
    end

    it 'returns results containing relevant units for a model query' do
      result = retriever.retrieve('How does the User model work?')

      source_identifiers = result.sources.map { |s| s[:identifier] }
      expect(source_identifiers).to include('User')
    end

    it 'includes structural context overview' do
      result = retriever.retrieve('How does the User model work?')

      expect(result.context).to include('Codebase:')
      expect(result.context).to include('units')
    end
  end

  describe 'query classification' do
    it 'classifies an understand intent' do
      result = retriever.retrieve('How does the User model work?')
      expect(result.classification.intent).to eq(:understand)
    end

    it 'classifies a locate intent' do
      result = retriever.retrieve('Where is the PostsController defined?')
      expect(result.classification.intent).to eq(:locate)
    end

    it 'classifies a trace intent' do
      result = retriever.retrieve('What calls the User model?')
      expect(result.classification.intent).to eq(:trace)
    end

    it 'classifies a debug intent' do
      result = retriever.retrieve('Why is the Post model broken?')
      expect(result.classification.intent).to eq(:debug)
    end

    it 'detects model target type' do
      result = retriever.retrieve('How does the User model work?')
      expect(result.classification.target_type).to eq(:model)
    end

    it 'detects controller target type' do
      result = retriever.retrieve('How does the controller handle requests?')
      expect(result.classification.target_type).to eq(:controller)
    end

    it 'extracts meaningful keywords' do
      result = retriever.retrieve('How does the User model work?')
      expect(result.classification.keywords).to include('user', 'model', 'work')
    end
  end

  describe 'search strategy selection' do
    it 'uses vector strategy for understand queries' do
      result = retriever.retrieve('How does the User model work?')
      expect(result.strategy).to eq(:vector)
    end

    it 'uses keyword strategy for locate queries' do
      result = retriever.retrieve('Where is the PostsController?')
      expect(result.strategy).to eq(:keyword)
    end

    it 'uses graph strategy for trace queries' do
      result = retriever.retrieve('What calls the User model?')
      expect(result.strategy).to eq(:graph)
    end

    it 'uses hybrid strategy for exploratory queries' do
      result = retriever.retrieve('Show me everything related to users')
      expect(result.strategy).to eq(:hybrid)
    end
  end

  describe 'ranking' do
    it 'returns candidates ordered by descending relevance' do
      result = retriever.retrieve('How does the User model work?')
      scores = result.sources.map { |s| s[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it 'applies RRF for hybrid queries' do
      result = retriever.retrieve('Show me everything related to users')

      # Hybrid queries use multiple sources → RRF is applied
      expect(result.strategy).to eq(:hybrid)
      expect(result.trace.candidate_count).to be_positive
      expect(result.trace.ranked_count).to be_positive
    end
  end

  describe 'budget enforcement' do
    it 'respects a small token budget' do
      result = retriever.retrieve('How does the User model work?', budget: 500)

      expect(result.tokens_used).to be <= 500
      expect(result.budget).to eq(500)
    end

    it 'includes fewer sources with a tight budget' do
      large_result = retriever.retrieve('How does the User model work?', budget: 8000)
      small_result = retriever.retrieve('How does the User model work?', budget: 200)

      expect(small_result.sources.size).to be <= large_result.sources.size
    end

    it 'respects a custom budget parameter' do
      result = retriever.retrieve('How does the User model work?', budget: 4000)
      expect(result.budget).to eq(4000)
    end
  end

  describe 'context assembly sections' do
    it 'separates sections with dividers' do
      result = retriever.retrieve('How does the User model work?')
      expect(result.context).to include('---')
    end

    it 'formats units with identifier and type headers' do
      result = retriever.retrieve('How does the User model work?')

      # Context should contain formatted unit headers
      expect(result.context).to match(/## \w+ \(\w+\)/)
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
      # Metadata store: store the full unit data as a hash
      metadata_store.store(unit.identifier, {
                             type: unit.type.to_s,
                             identifier: unit.identifier,
                             file_path: unit.file_path,
                             namespace: unit.namespace,
                             source_code: unit.source_code,
                             metadata: unit.metadata,
                             dependencies: unit.dependencies
                           })

      # Vector store: embed and store the source code
      vector = embedding_provider.embed(unit.source_code)
      vector_store.store(unit.identifier, vector, { type: unit.type.to_s })

      # Graph store: register the unit for dependency tracking
      graph_store.register(unit)
    end
  end
end
