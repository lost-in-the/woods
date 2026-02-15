# Retriever Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the Retriever orchestrator, context formatting adapters, production hardening (CircuitBreaker, RetryableProvider, IndexValidator), observability (Instrumentation, StructuredLogger, HealthCheck), vector store adapters (Pgvector, Qdrant), OpenAI embedding adapter, MCP semantic search tool, and retrieval rake tasks.

**Architecture:** 5 parallel agents in git worktrees, each owning non-overlapping files. Phase 1 agents (retriever, formatting, infra) have no dependencies. Phase 2 agents (resilience, mcp) depend on the Retriever being merged. All code is TDD with specs using mocks — no external services needed.

**Tech Stack:** Ruby, RSpec, `net/http`, `ActiveSupport::Notifications` (optional), `sqlite3` (existing dep), `mcp` gem (existing dep)

**Design Doc:** `docs/plans/2026-02-15-retriever-design.md`

---

## Worktree Setup

Before dispatching agents, the lead creates 5 worktrees from main:

```bash
git worktree add ../rails-tokenizer-retriever -b feat/retriever
git worktree add ../rails-tokenizer-formatting -b feat/formatting
git worktree add ../rails-tokenizer-infra -b feat/infra
git worktree add ../rails-tokenizer-resilience -b feat/resilience
git worktree add ../rails-tokenizer-mcp -b feat/mcp-retrieve
```

Each agent runs `bundle install` in its worktree before starting.

---

## Agent 1: retriever-agent (Phase 1)

**Worktree:** `../rails-tokenizer-retriever`
**Branch:** `feat/retriever`
**Backlog items:** B-038, B-039

### Task 1: Retriever — RetrievalResult struct + basic orchestration

**Files:**
- Create: `lib/codebase_index/retriever.rb`
- Test: `spec/retriever_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/retriever_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/retriever'
require 'codebase_index/retrieval/query_classifier'
require 'codebase_index/retrieval/search_executor'
require 'codebase_index/retrieval/ranker'
require 'codebase_index/retrieval/context_assembler'

RSpec.describe CodebaseIndex::Retriever do
  let(:vector_store) { instance_double('VectorStore') }
  let(:metadata_store) { instance_double('MetadataStore') }
  let(:graph_store) { instance_double('GraphStore') }
  let(:embedding_provider) { instance_double('EmbeddingProvider') }

  subject(:retriever) do
    described_class.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: embedding_provider
    )
  end

  describe '#retrieve' do
    let(:query) { 'How does User model handle validation?' }
    let(:classification) do
      CodebaseIndex::Retrieval::QueryClassifier::Classification.new(
        intent: :understand, scope: :focused, target_type: :model,
        framework_context: false, keywords: %w[user model handle validation]
      )
    end
    let(:candidate) do
      CodebaseIndex::Retrieval::SearchExecutor::Candidate.new(
        identifier: 'User', score: 0.9, source: :vector, metadata: { type: 'model' }
      )
    end
    let(:execution_result) do
      CodebaseIndex::Retrieval::SearchExecutor::ExecutionResult.new(
        candidates: [candidate], strategy: :vector, query: query
      )
    end
    let(:assembled) do
      CodebaseIndex::Retrieval::AssembledContext.new(
        context: '## User (model)', tokens_used: 100, budget: 8000,
        sources: [{ identifier: 'User', type: 'model', score: 0.9 }],
        sections: [:primary]
      )
    end

    before do
      allow_any_instance_of(CodebaseIndex::Retrieval::QueryClassifier)
        .to receive(:classify).and_return(classification)
      allow_any_instance_of(CodebaseIndex::Retrieval::SearchExecutor)
        .to receive(:execute).and_return(execution_result)
      allow_any_instance_of(CodebaseIndex::Retrieval::Ranker)
        .to receive(:rank).and_return([candidate])
      allow_any_instance_of(CodebaseIndex::Retrieval::ContextAssembler)
        .to receive(:assemble).and_return(assembled)
    end

    it 'returns a RetrievalResult' do
      result = retriever.retrieve(query)
      expect(result).to be_a(CodebaseIndex::Retriever::RetrievalResult)
    end

    it 'includes the assembled context' do
      result = retriever.retrieve(query)
      expect(result.context).to eq('## User (model)')
    end

    it 'includes the query classification' do
      result = retriever.retrieve(query)
      expect(result.classification).to eq(classification)
    end

    it 'includes the search strategy' do
      result = retriever.retrieve(query)
      expect(result.strategy).to eq(:vector)
    end

    it 'includes source attributions' do
      result = retriever.retrieve(query)
      expect(result.sources).to include(hash_including(identifier: 'User'))
    end

    it 'accepts an optional token budget' do
      result = retriever.retrieve(query, budget: 4000)
      expect(result).to be_a(CodebaseIndex::Retriever::RetrievalResult)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/retriever_spec.rb`
Expected: FAIL — `cannot load such file -- codebase_index/retriever`

**Step 3: Write minimal implementation**

```ruby
# lib/codebase_index/retriever.rb
# frozen_string_literal: true

require_relative 'retrieval/query_classifier'
require_relative 'retrieval/search_executor'
require_relative 'retrieval/ranker'
require_relative 'retrieval/context_assembler'

module CodebaseIndex
  # Top-level retrieval entry point. Orchestrates:
  # classify → search → rank → assemble → format
  #
  # @example
  #   retriever = Retriever.new(vector_store: vs, metadata_store: ms,
  #                             graph_store: gs, embedding_provider: ep)
  #   result = retriever.retrieve("How does User model handle validation?")
  #
  class Retriever
    RetrievalResult = Struct.new(:context, :sources, :classification, :strategy,
                                 :tokens_used, :budget, keyword_init: true)

    # @param vector_store [Storage::VectorStore::Interface]
    # @param metadata_store [Storage::MetadataStore::Interface]
    # @param graph_store [Storage::GraphStore::Interface]
    # @param embedding_provider [Embedding::Provider::Interface]
    # @param formatter [Formatting::Base, nil] Optional context formatter
    def initialize(vector_store:, metadata_store:, graph_store:, embedding_provider:, formatter: nil)
      @classifier = Retrieval::QueryClassifier.new
      @executor = Retrieval::SearchExecutor.new(
        vector_store: vector_store,
        metadata_store: metadata_store,
        graph_store: graph_store,
        embedding_provider: embedding_provider
      )
      @ranker = Retrieval::Ranker.new(metadata_store: metadata_store)
      @assembler = Retrieval::ContextAssembler.new(metadata_store: metadata_store)
      @metadata_store = metadata_store
      @formatter = formatter
    end

    # Retrieve context for a natural language query.
    #
    # @param query [String] Natural language query
    # @param budget [Integer] Token budget (default: 8000)
    # @return [RetrievalResult]
    def retrieve(query, budget: 8000)
      classification = @classifier.classify(query)
      execution = @executor.execute(query: query, classification: classification)
      ranked = @ranker.rank(execution.candidates, classification: classification)
      assembled = @assembler.assemble(
        candidates: ranked, classification: classification,
        structural_context: build_structural_context
      )

      context = @formatter ? @formatter.format(assembled) : assembled.context

      RetrievalResult.new(
        context: context,
        sources: assembled.sources,
        classification: classification,
        strategy: execution.strategy,
        tokens_used: assembled.tokens_used,
        budget: assembled.budget
      )
    end

    private

    # Build a brief structural overview of the codebase from metadata store.
    #
    # @return [String, nil]
    def build_structural_context
      # Will be enhanced in StructuralContextBuilder task
      nil
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/retriever_spec.rb`
Expected: All PASS

**Step 5: Commit**

```bash
git add lib/codebase_index/retriever.rb spec/retriever_spec.rb
git commit -m "Add Retriever orchestrator with RetrievalResult struct"
```

### Task 2: StructuralContextBuilder

**Files:**
- Modify: `lib/codebase_index/retriever.rb`
- Modify: `spec/retriever_spec.rb`

**Step 1: Add failing test for structural context**

Add to `spec/retriever_spec.rb`:

```ruby
describe '#build_structural_context' do
  before do
    allow(metadata_store).to receive(:count).and_return(50)
    allow(metadata_store).to receive(:find_by_type).and_return([])
  end

  it 'generates a codebase overview string' do
    # Access private method via send for testing
    context = retriever.send(:build_structural_context)
    expect(context).to be_a(String)
    expect(context).to include('50 units')
  end
end
```

**Step 2: Run to verify failure**

Run: `bundle exec rspec spec/retriever_spec.rb`
Expected: FAIL — count not defined or nil return

**Step 3: Implement StructuralContextBuilder in retriever.rb**

Replace the `build_structural_context` private method:

```ruby
# Build a brief structural overview of the codebase from metadata store.
#
# @return [String, nil]
def build_structural_context
  total = @metadata_store.count
  return nil if total.zero?

  type_counts = count_by_type
  overview = "Codebase: #{total} units"
  type_summary = type_counts.map { |t, c| "#{c} #{t}s" }.join(', ')
  "#{overview} (#{type_summary})"
rescue StandardError
  nil
end

# Count units by type for the structural overview.
#
# @return [Hash<String, Integer>]
def count_by_type
  %w[model controller service job mailer component graphql].each_with_object({}) do |type, counts|
    units = @metadata_store.find_by_type(type)
    counts[type] = units.size if units.any?
  end
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/retriever_spec.rb`
Expected: All PASS

**Step 5: Rubocop + commit**

```bash
bundle exec rubocop -a lib/codebase_index/retriever.rb spec/retriever_spec.rb
git add -A && git commit -m "Add StructuralContextBuilder to Retriever"
```

---

## Agent 2: formatting-agent (Phase 1)

**Worktree:** `../rails-tokenizer-formatting`
**Branch:** `feat/formatting`
**Backlog items:** B-040, B-041

### Task 3: Formatting::Base + ClaudeAdapter

**Files:**
- Create: `lib/codebase_index/formatting/base.rb`
- Create: `lib/codebase_index/formatting/claude_adapter.rb`
- Test: `spec/formatting/base_spec.rb`
- Test: `spec/formatting/claude_adapter_spec.rb`

**Step 1: Write failing tests**

```ruby
# spec/formatting/base_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/formatting/base'

RSpec.describe CodebaseIndex::Formatting::Base do
  it 'raises NotImplementedError for #format' do
    expect { described_class.new.format(double) }.to raise_error(NotImplementedError)
  end
end
```

```ruby
# spec/formatting/claude_adapter_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/formatting/claude_adapter'
require 'codebase_index/retrieval/context_assembler'

RSpec.describe CodebaseIndex::Formatting::ClaudeAdapter do
  subject(:adapter) { described_class.new }

  let(:assembled) do
    CodebaseIndex::Retrieval::AssembledContext.new(
      context: "## User (model)\nFile: app/models/user.rb\n\nclass User; end",
      tokens_used: 100,
      budget: 8000,
      sources: [{ identifier: 'User', type: 'model', score: 0.9, file_path: 'app/models/user.rb' }],
      sections: %i[structural primary]
    )
  end

  describe '#format' do
    it 'wraps content in XML tags' do
      result = adapter.format(assembled)
      expect(result).to include('<codebase-context>')
      expect(result).to include('</codebase-context>')
    end

    it 'includes unit content' do
      result = adapter.format(assembled)
      expect(result).to include('class User; end')
    end

    it 'includes source attributions' do
      result = adapter.format(assembled)
      expect(result).to include('<sources>')
      expect(result).to include('User')
    end

    it 'includes token usage metadata' do
      result = adapter.format(assembled)
      expect(result).to include('100')
    end
  end
end
```

**Step 2: Run to verify failure**

Run: `bundle exec rspec spec/formatting/`
Expected: FAIL — cannot load files

**Step 3: Implement Base and ClaudeAdapter**

```ruby
# lib/codebase_index/formatting/base.rb
# frozen_string_literal: true

module CodebaseIndex
  module Formatting
    # Abstract base class for context formatters.
    #
    # Subclasses must implement {#format} to transform an {AssembledContext}
    # into an LLM-appropriate string.
    class Base
      # Format assembled context for a specific LLM.
      #
      # @param assembled_context [Retrieval::AssembledContext]
      # @return [String] Formatted context
      def format(_assembled_context)
        raise NotImplementedError, "#{self.class}#format must be implemented"
      end

      private

      # Estimate token count.
      #
      # @param text [String]
      # @return [Integer]
      def estimate_tokens(text)
        (text.length / 3.5).ceil
      end
    end
  end
end
```

```ruby
# lib/codebase_index/formatting/claude_adapter.rb
# frozen_string_literal: true

require_relative 'base'

module CodebaseIndex
  module Formatting
    # Formats retrieval context as XML for Claude models.
    #
    # Claude performs best with XML-structured context that uses semantic tags.
    # Overhead: ~40 tokens per unit for XML tags.
    #
    # @example
    #   adapter = ClaudeAdapter.new
    #   xml = adapter.format(assembled_context)
    #
    class ClaudeAdapter < Base
      # @param assembled_context [Retrieval::AssembledContext]
      # @return [String] XML-formatted context
      def format(assembled_context)
        parts = []
        parts << '<codebase-context>'
        parts << "  <meta tokens=\"#{assembled_context.tokens_used}\" budget=\"#{assembled_context.budget}\" />"
        parts << format_content(assembled_context.context)
        parts << format_sources(assembled_context.sources)
        parts << '</codebase-context>'
        parts.join("\n")
      end

      private

      def format_content(context)
        "  <content>\n#{indent(context, 4)}\n  </content>"
      end

      def format_sources(sources)
        return '' if sources.nil? || sources.empty?

        lines = ['  <sources>']
        sources.each do |s|
          attrs = source_attributes(s)
          lines << "    <source #{attrs} />"
        end
        lines << '  </sources>'
        lines.join("\n")
      end

      def source_attributes(source)
        parts = []
        parts << "identifier=\"#{escape_xml(source[:identifier])}\"" if source[:identifier]
        parts << "type=\"#{source[:type]}\"" if source[:type]
        parts << "score=\"#{source[:score]}\"" if source[:score]
        parts << "file=\"#{escape_xml(source[:file_path])}\"" if source[:file_path]
        parts << 'truncated="true"' if source[:truncated]
        parts.join(' ')
      end

      def indent(text, spaces)
        text.lines.map { |l| "#{' ' * spaces}#{l}" }.join
      end

      def escape_xml(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end
    end
  end
end
```

**Step 4: Run tests**

Run: `bundle exec rspec spec/formatting/`
Expected: All PASS

**Step 5: Commit**

```bash
bundle exec rubocop -a lib/codebase_index/formatting/ spec/formatting/
git add -A && git commit -m "Add Formatting::Base and ClaudeAdapter (XML)"
```

### Task 4: GPTAdapter + GenericAdapter + HumanAdapter

**Files:**
- Create: `lib/codebase_index/formatting/gpt_adapter.rb`
- Create: `lib/codebase_index/formatting/generic_adapter.rb`
- Create: `lib/codebase_index/formatting/human_adapter.rb`
- Test: `spec/formatting/gpt_adapter_spec.rb`
- Test: `spec/formatting/generic_adapter_spec.rb`
- Test: `spec/formatting/human_adapter_spec.rb`

Follow the same TDD pattern as Task 3. Key differences:

- **GPTAdapter**: Uses Markdown headers (`##`), fenced code blocks (` ```ruby `), and bullet lists for sources. Overhead: ~30 tokens/unit.
- **GenericAdapter**: Plain text with `---` separators and `[Source: ...]` lines. Overhead: ~20 tokens/unit. Minimal formatting.
- **HumanAdapter**: Box-drawing chars (`┌─┐`, `│`, `└─┘`), section headers, compact source table. For CLI/terminal display.

Each adapter spec follows the same structure as `claude_adapter_spec.rb` — create an `AssembledContext`, call `format`, assert on format-specific patterns.

**Commit:** `git commit -m "Add GPT, Generic, and Human context formatting adapters"`

---

## Agent 3: infra-agent (Phase 1)

**Worktree:** `../rails-tokenizer-infra`
**Branch:** `feat/infra`
**Backlog items:** B-042 through B-046

### Task 5: Pgvector vector store adapter

**Files:**
- Create: `lib/codebase_index/storage/pgvector.rb`
- Test: `spec/storage/pgvector_spec.rb`

**Step 1: Write failing test**

```ruby
# spec/storage/pgvector_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/pgvector'

RSpec.describe CodebaseIndex::Storage::VectorStore::Pgvector do
  let(:connection) { instance_double('ActiveRecord::Connection') }
  let(:result_rows) { [] }

  subject(:store) { described_class.new(connection: connection, dimensions: 3) }

  before do
    allow(connection).to receive(:execute)
    allow(connection).to receive(:exec_query).and_return(double(rows: result_rows, to_a: result_rows))
    allow(connection).to receive(:quote) { |v| "'#{v}'" }
  end

  describe '#store' do
    it 'inserts a vector with metadata via parameterized query' do
      expect(connection).to receive(:execute).with(/INSERT INTO codebase_index_vectors/)
      store.store('User', [0.1, 0.2, 0.3], { type: 'model' })
    end
  end

  describe '#search' do
    let(:result_rows) do
      [{ 'id' => 'User', 'score' => 0.95, 'metadata' => '{"type":"model"}' }]
    end

    it 'returns SearchResult objects sorted by similarity' do
      results = store.search([0.1, 0.2, 0.3], limit: 5)
      expect(results.first).to be_a(CodebaseIndex::Storage::VectorStore::SearchResult)
      expect(results.first.id).to eq('User')
    end
  end

  describe '#delete' do
    it 'removes a vector by ID' do
      expect(connection).to receive(:execute).with(/DELETE FROM codebase_index_vectors WHERE id/)
      store.delete('User')
    end
  end

  describe '#count' do
    let(:result_rows) { [{ 'count' => 42 }] }

    it 'returns total vector count' do
      expect(store.count).to eq(42)
    end
  end

  describe '#ensure_schema!' do
    it 'creates the pgvector extension and table' do
      expect(connection).to receive(:execute).with(/CREATE EXTENSION IF NOT EXISTS vector/)
      expect(connection).to receive(:execute).with(/CREATE TABLE IF NOT EXISTS codebase_index_vectors/)
      store.ensure_schema!
    end
  end
end
```

**Step 2: Run to verify failure**

Run: `bundle exec rspec spec/storage/pgvector_spec.rb`

**Step 3: Implement**

```ruby
# lib/codebase_index/storage/pgvector.rb
# frozen_string_literal: true

require_relative 'vector_store'

module CodebaseIndex
  module Storage
    module VectorStore
      # Pgvector adapter for PostgreSQL vector similarity search.
      #
      # Uses the pgvector extension with HNSW indexing. All queries use
      # parameterized SQL to prevent injection.
      #
      # @example
      #   store = Pgvector.new(connection: ActiveRecord::Base.connection, dimensions: 1536)
      #   store.ensure_schema!
      #   store.store("User", embedding_vector, { type: "model" })
      #
      class Pgvector
        include Interface

        TABLE = 'codebase_index_vectors'

        # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
        # @param dimensions [Integer] Vector dimensions (must match embedding model)
        def initialize(connection:, dimensions:)
          @connection = connection
          @dimensions = dimensions
        end

        # Create pgvector extension, table, and HNSW index.
        def ensure_schema!
          @connection.execute('CREATE EXTENSION IF NOT EXISTS vector')
          @connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{TABLE} (
              id TEXT PRIMARY KEY,
              embedding vector(#{@dimensions}),
              metadata JSONB DEFAULT '{}'::jsonb,
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
          SQL
          @connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_#{TABLE}_embedding
            ON #{TABLE} USING hnsw (embedding vector_cosine_ops)
          SQL
        end

        def store(id, vector, metadata = {})
          vector_literal = "[#{vector.join(',')}]"
          meta_json = JSON.generate(metadata)
          @connection.execute(
            "INSERT INTO #{TABLE} (id, embedding, metadata) VALUES " \
            "(#{@connection.quote(id)}, #{@connection.quote(vector_literal)}::vector, " \
            "#{@connection.quote(meta_json)}::jsonb) " \
            "ON CONFLICT (id) DO UPDATE SET embedding = EXCLUDED.embedding, " \
            "metadata = EXCLUDED.metadata"
          )
        end

        def search(query_vector, limit: 10, filters: {})
          vector_literal = "[#{query_vector.join(',')}]"
          where_clause = build_where(filters)
          sql = "SELECT id, 1 - (embedding <=> #{@connection.quote(vector_literal)}::vector) AS score, " \
                "metadata::text FROM #{TABLE}#{where_clause} " \
                "ORDER BY embedding <=> #{@connection.quote(vector_literal)}::vector LIMIT #{limit.to_i}"
          rows = @connection.exec_query(sql).to_a
          rows.map do |row|
            SearchResult.new(
              id: row['id'],
              score: row['score'].to_f,
              metadata: JSON.parse(row['metadata'] || '{}')
            )
          end
        end

        def delete(id)
          @connection.execute("DELETE FROM #{TABLE} WHERE id = #{@connection.quote(id)}")
        end

        def delete_by_filter(filters)
          where_clause = build_where(filters)
          return if where_clause.empty?

          @connection.execute("DELETE FROM #{TABLE}#{where_clause}")
        end

        def count
          result = @connection.exec_query("SELECT COUNT(*) AS count FROM #{TABLE}").to_a
          result.first&.fetch('count', 0).to_i
        end

        private

        def build_where(filters)
          return '' if filters.empty?

          conditions = filters.map do |key, value|
            "metadata->>#{@connection.quote(key.to_s)} = #{@connection.quote(value.to_s)}"
          end
          " WHERE #{conditions.join(' AND ')}"
        end
      end
    end
  end
end
```

**Step 4:** Run tests. **Step 5:** Rubocop + commit: `"Add Pgvector vector store adapter"`

### Task 6: Qdrant vector store adapter

Same TDD pattern. Key differences:
- Uses `net/http` to talk to Qdrant REST API (`POST /collections/{name}/points/search`)
- Filter translation: `{ type: "model" }` → `{ "must": [{ "key": "type", "match": { "value": "model" } }] }`
- `ensure_collection!` creates the collection if missing via `PUT /collections/{name}`
- Mock `Net::HTTP` in specs

**Commit:** `"Add Qdrant vector store adapter"`

### Task 7: Instrumentation module

**Files:**
- Create: `lib/codebase_index/observability/instrumentation.rb`
- Test: `spec/observability/instrumentation_spec.rb`

```ruby
# lib/codebase_index/observability/instrumentation.rb
# frozen_string_literal: true

module CodebaseIndex
  module Observability
    # Thin instrumentation wrapper. Uses ActiveSupport::Notifications when
    # available, falls back to direct yield otherwise.
    module Instrumentation
      module_function

      # Instrument a block with a named event.
      #
      # @param event [String] Event name (e.g. "codebase_index.retrieve")
      # @param payload [Hash] Additional event data
      # @return [Object] Block return value
      def instrument(event, payload = {}, &block)
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(event, payload, &block)
        else
          yield
        end
      end
    end
  end
end
```

Spec tests both paths: with ActiveSupport stubbed in, and with it undefined.

**Commit:** `"Add Observability::Instrumentation module"`

### Task 8: StructuredLogger

**Files:**
- Create: `lib/codebase_index/observability/structured_logger.rb`
- Test: `spec/observability/structured_logger_spec.rb`

Key behavior: `#info`, `#warn`, `#error`, `#debug` methods. Each writes one JSON line to the configured output IO. Spec uses `StringIO` to capture output.

**Commit:** `"Add Observability::StructuredLogger"`

### Task 9: HealthCheck

**Files:**
- Create: `lib/codebase_index/observability/health_check.rb`
- Test: `spec/observability/health_check_spec.rb`

Key behavior: Takes component instances, probes each (`count` for stores, test `embed` for provider), returns `HealthStatus` struct with `healthy?` and `components` hash. Components that raise return `:error` status.

**Commit:** `"Add Observability::HealthCheck"`

---

## Agent 4: resilience-agent (Phase 2)

**Worktree:** `../rails-tokenizer-resilience`
**Branch:** `feat/resilience`
**Backlog items:** B-047, B-048, B-049

> **Prerequisite:** Rebase onto main after retriever-agent's branch is merged.

### Task 10: CircuitBreaker

**Files:**
- Create: `lib/codebase_index/resilience/circuit_breaker.rb`
- Test: `spec/resilience/circuit_breaker_spec.rb`

**Step 1: Write failing test**

```ruby
# spec/resilience/circuit_breaker_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/resilience/circuit_breaker'

RSpec.describe CodebaseIndex::Resilience::CircuitBreaker do
  subject(:breaker) { described_class.new(threshold: 3, reset_timeout: 0.1) }

  describe '#call' do
    it 'passes through when circuit is closed' do
      result = breaker.call { 42 }
      expect(result).to eq(42)
    end

    it 'opens after threshold failures' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      expect { breaker.call { 1 } }.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
    end

    it 'transitions to half-open after reset_timeout' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      sleep 0.15
      # Half-open allows one test call
      result = breaker.call { 99 }
      expect(result).to eq(99)
    end

    it 'closes again after a successful half-open call' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      sleep 0.15
      breaker.call { 1 } # half-open success
      # Should be closed now
      result = breaker.call { 2 }
      expect(result).to eq(2)
    end

    it 're-opens if half-open test call fails' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      sleep 0.15
      breaker.call { raise 'still broken' } rescue nil
      expect { breaker.call { 1 } }.to raise_error(CodebaseIndex::Resilience::CircuitOpenError)
    end
  end

  describe '#state' do
    it 'starts closed' do
      expect(breaker.state).to eq(:closed)
    end
  end
end
```

**Step 2:** Run to verify failure.

**Step 3: Implement**

```ruby
# lib/codebase_index/resilience/circuit_breaker.rb
# frozen_string_literal: true

module CodebaseIndex
  module Resilience
    class CircuitOpenError < CodebaseIndex::Error; end

    # Circuit breaker for protecting external service calls.
    #
    # States: :closed → :open → :half_open → :closed (or back to :open)
    #
    # @example
    #   breaker = CircuitBreaker.new(threshold: 5, reset_timeout: 60)
    #   breaker.call { http_request }
    #
    class CircuitBreaker
      attr_reader :state

      # @param threshold [Integer] Failures before opening (default: 5)
      # @param reset_timeout [Numeric] Seconds before half-open (default: 60)
      def initialize(threshold: 5, reset_timeout: 60)
        @threshold = threshold
        @reset_timeout = reset_timeout
        @state = :closed
        @failure_count = 0
        @last_failure_at = nil
      end

      # Execute a block through the circuit breaker.
      #
      # @raise [CircuitOpenError] if circuit is open
      # @return [Object] Block return value
      def call(&block)
        case @state
        when :closed
          execute_closed(&block)
        when :open
          try_half_open(&block)
        when :half_open
          execute_half_open(&block)
        end
      end

      private

      def execute_closed(&block)
        result = yield
        reset!
        result
      rescue StandardError => e
        record_failure
        raise e
      end

      def try_half_open(&block)
        if Time.now - @last_failure_at >= @reset_timeout
          @state = :half_open
          execute_half_open(&block)
        else
          raise CircuitOpenError, "Circuit is open (#{@failure_count} failures)"
        end
      end

      def execute_half_open(&block)
        result = yield
        reset!
        result
      rescue StandardError => e
        @state = :open
        @last_failure_at = Time.now
        raise e
      end

      def record_failure
        @failure_count += 1
        @last_failure_at = Time.now
        @state = :open if @failure_count >= @threshold
      end

      def reset!
        @failure_count = 0
        @state = :closed
      end
    end
  end
end
```

**Step 4:** Run tests. **Step 5:** Commit: `"Add Resilience::CircuitBreaker"`

### Task 11: RetryableProvider

**Files:**
- Create: `lib/codebase_index/resilience/retryable_provider.rb`
- Test: `spec/resilience/retryable_provider_spec.rb`

Wraps any `Embedding::Provider::Interface`. Delegates `embed`, `embed_batch`, `dimensions`, `model_name`. Retries with exponential backoff on StandardError (not CircuitOpenError). Spec uses a mock provider that fails N times then succeeds.

**Commit:** `"Add Resilience::RetryableProvider with exponential backoff"`

### Task 12: IndexValidator

**Files:**
- Create: `lib/codebase_index/resilience/index_validator.rb`
- Test: `spec/resilience/index_validator_spec.rb`

Uses `shared_extractor_context` to create temp dirs with fixture JSON files. Tests: valid index passes, missing files produce errors, bad hashes produce warnings, empty dir returns errors.

**Commit:** `"Add Resilience::IndexValidator for index health checks"`

---

## Agent 5: mcp-agent (Phase 2)

**Worktree:** `../rails-tokenizer-mcp`
**Branch:** `feat/mcp-retrieve`
**Backlog items:** B-050, B-051, B-052

> **Prerequisite:** Rebase onto main after retriever-agent's branch is merged.

### Task 13: OpenAI embedding adapter

**Files:**
- Create: `lib/codebase_index/embedding/openai.rb`
- Test: `spec/embedding/openai_spec.rb`

**Step 1: Write failing test**

```ruby
# spec/embedding/openai_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/embedding/openai'

RSpec.describe CodebaseIndex::Embedding::Provider::OpenAI do
  subject(:provider) { described_class.new(api_key: 'test-key') }

  let(:success_response) do
    {
      'data' => [{ 'embedding' => [0.1, 0.2, 0.3] }],
      'model' => 'text-embedding-3-small',
      'usage' => { 'total_tokens' => 5 }
    }
  end

  before do
    stub_request(:post, 'https://api.openai.com/v1/embeddings')
      .to_return(status: 200, body: JSON.generate(success_response))
  end

  describe '#embed' do
    it 'returns a vector array' do
      result = provider.embed('test text')
      expect(result).to eq([0.1, 0.2, 0.3])
    end
  end

  describe '#embed_batch' do
    let(:batch_response) do
      {
        'data' => [
          { 'embedding' => [0.1, 0.2, 0.3] },
          { 'embedding' => [0.4, 0.5, 0.6] }
        ]
      }
    end

    before do
      stub_request(:post, 'https://api.openai.com/v1/embeddings')
        .to_return(status: 200, body: JSON.generate(batch_response))
    end

    it 'returns array of vectors' do
      result = provider.embed_batch(['text1', 'text2'])
      expect(result.size).to eq(2)
    end
  end

  describe '#model_name' do
    it 'returns the configured model' do
      expect(provider.model_name).to eq('text-embedding-3-small')
    end
  end

  describe '#dimensions' do
    it 'returns dimensions based on model' do
      expect(provider.dimensions).to eq(1536)
    end
  end

  context 'with API error' do
    before do
      stub_request(:post, 'https://api.openai.com/v1/embeddings')
        .to_return(status: 429, body: '{"error":{"message":"rate limited"}}')
    end

    it 'raises CodebaseIndex::Error' do
      expect { provider.embed('test') }.to raise_error(CodebaseIndex::Error, /429/)
    end
  end
end
```

Note: This spec uses `webmock` or manual Net::HTTP stubbing. If `webmock` isn't available, stub `Net::HTTP` directly like the Ollama specs do.

**Step 2:** Run to verify failure.

**Step 3: Implement**

```ruby
# lib/codebase_index/embedding/openai.rb
# frozen_string_literal: true

require 'net/http'
require 'json'
require_relative 'provider'

module CodebaseIndex
  module Embedding
    module Provider
      # OpenAI embedding adapter using the /v1/embeddings API.
      #
      # @example
      #   provider = OpenAI.new(api_key: ENV['OPENAI_API_KEY'])
      #   vector = provider.embed("class User; end")
      #
      class OpenAI
        include Interface

        ENDPOINT = URI('https://api.openai.com/v1/embeddings')
        DEFAULT_MODEL = 'text-embedding-3-small'

        DIMENSIONS = {
          'text-embedding-3-small' => 1536,
          'text-embedding-3-large' => 3072
        }.freeze

        # @param api_key [String] OpenAI API key
        # @param model [String] Model name (default: text-embedding-3-small)
        def initialize(api_key:, model: DEFAULT_MODEL)
          @api_key = api_key
          @model = model
        end

        def embed(text)
          response = post_request(input: text, model: @model)
          response['data'].first['embedding']
        end

        def embed_batch(texts)
          response = post_request(input: texts, model: @model)
          response['data'].sort_by { |d| d['index'] }.map { |d| d['embedding'] }
        end

        def dimensions
          DIMENSIONS[@model] || DIMENSIONS[DEFAULT_MODEL]
        end

        def model_name
          @model
        end

        private

        def post_request(body)
          http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
          http.use_ssl = true

          request = Net::HTTP::Post.new(ENDPOINT.path)
          request['Authorization'] = "Bearer #{@api_key}"
          request['Content-Type'] = 'application/json'
          request.body = JSON.generate(body)

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "OpenAI API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        end
      end
    end
  end
end
```

**Step 4:** Run tests. **Step 5:** Commit: `"Add OpenAI embedding provider adapter"`

### Task 14: MCP codebase_retrieve tool

**Files:**
- Modify: `lib/codebase_index/mcp/server.rb`
- Modify: `spec/mcp/server_spec.rb`

Add `define_retrieve_tool` method following the existing tool pattern. The tool accepts `query` (required) and `budget` (optional, default 8000). When no Retriever is configured, it falls back to the existing `search` tool behavior with a note that semantic search requires embedding configuration.

The `Server.build` method gains an optional `retriever:` parameter.

**Commit:** `"Add codebase_retrieve semantic search tool to MCP server"`

### Task 15: Retrieval + embedding rake tasks

**Files:**
- Modify: `lib/tasks/codebase_index.rake`
- Test: Manual verification (rake tasks test in host app)

Add three tasks:

```ruby
desc 'Retrieve context for a query (for testing)'
task :retrieve, [:query] => :environment do |_t, args|
  # Build retriever from config, call retrieve, print result
end

desc 'Embed all extracted units'
task embed: :environment do
  # Build indexer from config, call index_all, print stats
end

desc 'Embed changed units only'
task embed_incremental: :environment do
  # Build indexer from config, call index_incremental, print stats
end
```

**Commit:** `"Add retrieve, embed, and embed_incremental rake tasks"`

---

## Lead: Phase 3 — Merge & Finalize

### Task 16: Merge Phase 1 branches

```bash
# From main
git merge feat/retriever --no-ff -m "Merge retriever orchestrator"
git merge feat/formatting --no-ff -m "Merge context formatting adapters"
git merge feat/infra --no-ff -m "Merge infra: pgvector, qdrant, observability"
```

Run full suite after each merge:
```bash
bundle exec rspec --format progress --format json --out tmp/test_results.json
```

### Task 17: Merge Phase 2 branches

```bash
git merge feat/resilience --no-ff -m "Merge resilience: circuit breaker, retryable provider, index validator"
git merge feat/mcp-retrieve --no-ff -m "Merge MCP semantic search, OpenAI adapter, rake tasks"
```

Run full suite after each merge.

### Task 18: Update backlog + docs

- Add B-038 through B-052 to `docs/backlog.json` with `"status": "resolved"`
- Update `docs/README.md` status table (add rows for Formatting, Resilience, Observability as complete)
- Run `bundle exec rubocop` on entire codebase
- Final: `bundle exec rspec` — all green

```bash
git add docs/ && git commit -m "Update backlog and docs: B-038 through B-052 resolved"
```

### Task 19: Clean up worktrees

```bash
git worktree remove ../rails-tokenizer-retriever
git worktree remove ../rails-tokenizer-formatting
git worktree remove ../rails-tokenizer-infra
git worktree remove ../rails-tokenizer-resilience
git worktree remove ../rails-tokenizer-mcp
git branch -d feat/retriever feat/formatting feat/infra feat/resilience feat/mcp-retrieve
```
