# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extracted_unit'
require 'codebase_index/dependency_graph'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/metadata_store'
require 'codebase_index/storage/graph_store'
require 'codebase_index/retriever'
require 'codebase_index/formatting/claude_adapter'
require 'codebase_index/formatting/gpt_adapter'
require 'codebase_index/formatting/human_adapter'
require 'codebase_index/formatting/generic_adapter'

RSpec.describe 'Retrieval + Formatting Integration', :integration do
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
    CodebaseIndex::Retriever.new(
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
    CodebaseIndex::Retrieval::AssembledContext.new(
      context: retrieval_result.context,
      tokens_used: retrieval_result.tokens_used,
      budget: retrieval_result.budget,
      sources: retrieval_result.sources,
      sections: %i[structural primary]
    )
  end

  # ── ClaudeAdapter ────────────────────────────────────────────────

  describe CodebaseIndex::Formatting::ClaudeAdapter do
    let(:adapter) { described_class.new }

    it 'produces XML-formatted output' do
      output = adapter.format(assembled_context)

      expect(output).to include('<codebase-context>')
      expect(output).to include('</codebase-context>')
    end

    it 'includes a meta tag with token and budget info' do
      output = adapter.format(assembled_context)

      expect(output).to include('<meta')
      expect(output).to match(/tokens="#{assembled_context.tokens_used}"/)
      expect(output).to match(/budget="#{assembled_context.budget}"/)
    end

    it 'includes a content section' do
      output = adapter.format(assembled_context)

      expect(output).to include('<content>')
      expect(output).to include('</content>')
    end

    it 'includes a sources section' do
      output = adapter.format(assembled_context)

      expect(output).to include('<sources>')
      expect(output).to include('</sources>')
    end

    it 'includes source elements for each source' do
      output = adapter.format(assembled_context)

      assembled_context.sources.each do |source|
        expect(output).to include("identifier=\"#{source[:identifier]}\"")
      end
    end

    it 'escapes XML special characters in content' do
      # The context might contain characters that need escaping
      output = adapter.format(assembled_context)

      # The content section should not contain unescaped < or > from Ruby code
      content_section = output[%r{<content>(.*?)</content>}m, 1]
      expect(content_section).not_to match(%r{<(?!/content>)}) if content_section
    end
  end

  # ── GptAdapter ───────────────────────────────────────────────────

  describe CodebaseIndex::Formatting::GptAdapter do
    let(:adapter) { described_class.new }

    it 'produces Markdown-formatted output' do
      output = adapter.format(assembled_context)

      expect(output).to include('## Codebase Context')
    end

    it 'includes token usage in bold' do
      output = adapter.format(assembled_context)

      expect(output).to include("**Tokens:** #{assembled_context.tokens_used}/#{assembled_context.budget}")
    end

    it 'wraps content in a Ruby code fence' do
      output = adapter.format(assembled_context)

      expect(output).to include('```ruby')
      expect(output).to include('```')
    end

    it 'includes a Sources section with bullet items' do
      output = adapter.format(assembled_context)

      expect(output).to include('### Sources')
      assembled_context.sources.each do |source|
        expect(output).to include("**#{source[:identifier]}**")
      end
    end
  end

  # ── HumanAdapter ─────────────────────────────────────────────────

  describe CodebaseIndex::Formatting::HumanAdapter do
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

  # ── GenericAdapter ───────────────────────────────────────────────

  describe CodebaseIndex::Formatting::GenericAdapter do
    let(:adapter) { described_class.new }

    it 'produces plain text output' do
      output = adapter.format(assembled_context)

      expect(output).to include('=== CODEBASE CONTEXT ===')
    end

    it 'includes token usage line' do
      output = adapter.format(assembled_context)

      expect(output).to include("Tokens: #{assembled_context.tokens_used} / #{assembled_context.budget}")
    end

    it 'includes content between dividers' do
      output = adapter.format(assembled_context)

      expect(output).to include('---')
    end

    it 'includes sources in bracket notation' do
      output = adapter.format(assembled_context)

      assembled_context.sources.each do |source|
        expect(output).to include("[Source: #{source[:identifier]}")
      end
    end
  end

  # ── Cross-adapter consistency ────────────────────────────────────

  describe 'cross-adapter consistency' do
    let(:adapters) do
      [
        CodebaseIndex::Formatting::ClaudeAdapter.new,
        CodebaseIndex::Formatting::GptAdapter.new,
        CodebaseIndex::Formatting::HumanAdapter.new,
        CodebaseIndex::Formatting::GenericAdapter.new
      ]
    end

    it 'all adapters produce non-empty output' do
      adapters.each do |adapter|
        output = adapter.format(assembled_context)
        expect(output).not_to be_empty, "#{adapter.class} produced empty output"
      end
    end

    it 'all adapters include content from the assembled context' do
      adapters.each do |adapter|
        output = adapter.format(assembled_context)
        # Each adapter should include at least some content from the context
        expect(output.length).to be > assembled_context.context.length / 2,
                                 "#{adapter.class} output is suspiciously short"
      end
    end
  end

  # ── Retriever with formatter integration ─────────────────────────

  describe 'Retriever with formatter callback' do
    it 'applies a formatter to the context' do
      formatted_retriever = CodebaseIndex::Retriever.new(
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
end
