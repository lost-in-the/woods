# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'woods'

# woods:retrieve used to construct its own stack — Ollama + InMemory +
# SQLite + Memory, hardcoded — while reading Woods.configuration for the
# token budget one line later. On a host configured for anything else
# (OpenAI + pgvector, say) it queried backends `woods:embed` never wrote to
# and silently returned nothing (#178). Same failure class as the embed
# tasks fixed by Woods::Tasks.build_embed_indexer, same spec strategy as
# spec/tasks/woods_rake_requires_spec.rb: pin the task body as text, then
# execute the extracted helper for real against an offline stack.
RSpec.describe 'lib/tasks/woods.rake woods:retrieve' do
  # Explicit UTF-8: the rake file has em dashes in its comments, and a
  # US-ASCII default external encoding makes every match? raise.
  let(:source) { File.read(File.expand_path('../../lib/tasks/woods.rake', __dir__), encoding: 'UTF-8') }

  # From the `task <name>` line to the next task/desc at the same indent.
  def task_body(name)
    lines = source.lines
    start = lines.index { |line| line.match?(/^  task[ :]+#{Regexp.escape(name)}\b/) }
    raise "could not locate the #{name} task in lib/tasks/woods.rake" if start.nil?

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.match?(/^  (desc|task)\b/) } || rest.length
    rest[0...stop].join
  end

  # From the `def <name>` line to the next def/desc/task at the same indent.
  def helper_body(name)
    lines = source.lines
    start = lines.index { |line| line.match?(/^  def #{Regexp.escape(name)}\b/) }
    raise "could not locate the #{name} helper in lib/tasks/woods.rake" if start.nil?

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.match?(/^  (def|desc|task)\b/) } || rest.length
    rest[0...stop].join
  end

  describe 'task body (text level)' do
    it 'delegates to the woods_run_retrieval helper' do
      expect(task_body('retrieve')).to include('woods_run_retrieval')
    end

    it 'resolves the whole stack through Woods::Builder from Woods.configuration' do
      body = helper_body('woods_run_retrieval')

      expect(body).to include('Woods::Builder.new(config).build_retriever')
      expect(body).to include('Woods.configuration')
    end

    it 'no longer constructs a hardcoded provider or stores anywhere in the rake file' do
      expect(source).not_to include('Woods::Embedding::Provider::Ollama.new')
      expect(source).not_to include('Woods::Storage::VectorStore::InMemory.new')
      expect(source).not_to include('Woods::Storage::MetadataStore::SQLite.new')
      expect(source).not_to include('Woods::Storage::GraphStore::Memory.new')
    end
  end

  describe 'woods_run_retrieval executed against the configured stack' do
    before { load File.expand_path('../../lib/tasks/woods.rake', __dir__) }

    # The helper reads the global Woods.configuration; isolate it so this
    # file neither inherits another spec's config nor leaks its own.
    around do |example|
      previous = Woods.configuration
      Woods.configuration = nil
      example.run
    ensure
      Woods.configuration = previous
    end

    def configure_offline_stack
      Woods.configure do |c|
        c.embedding_provider = :fake
        c.vector_store = :in_memory
        c.metadata_store = :in_memory
        c.graph_store = :in_memory
      end
    end

    # The end-to-end the issue calls out: with :fake configured, the task
    # helper must run with no network endpoint and no Rails boot at all.
    it 'runs fully offline with the :fake provider and in-memory stores' do
      configure_offline_stack

      expect(Woods::Embedding::Provider::Ollama).not_to receive(:new)

      output = Object.new.send(:woods_run_retrieval, 'How does authentication work?')

      expect(output).to include('Codebase Context')
    end

    it 'builds the retriever through Builder handed the live configuration' do
      configure_offline_stack

      builder = Woods::Builder.new(Woods.configuration)
      expect(Woods::Builder).to receive(:new).with(Woods.configuration).and_return(builder)

      Object.new.send(:woods_run_retrieval, 'anything at all')
    end

    it 'passes config.max_context_tokens as the retrieval budget' do
      configure_offline_stack
      Woods.configure { |c| c.max_context_tokens = 1234 }

      fake_retriever = instance_double(Woods::Retriever)
      allow_any_instance_of(Woods::Builder).to receive(:build_retriever).and_return(fake_retriever)
      result = Woods::Retriever::RetrievalResult.new(
        context: '', sources: [], strategy: :vector, tokens_used: 0, budget: 1234
      )
      expect(fake_retriever).to receive(:retrieve).with('q', budget: 1234).and_return(result)

      Object.new.send(:woods_run_retrieval, 'q')
    end
  end
end
