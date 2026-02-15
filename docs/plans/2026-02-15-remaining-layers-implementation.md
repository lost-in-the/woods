# Remaining Layers Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the 5 remaining layers: semantic chunking, schema management, agentic integration (operator + feedback + coordination), console MCP server (all 4 tiers), and evaluation harness.

**Architecture:** Two-wave agent team. Wave 1: 5 agents concurrently (chunking, schema, agentic, console-core, eval). Wave 2: 2 agents expand console (console-domain, console-advanced). All agents work in the main project directory with exclusive file ownership. No worktrees (permission boundary limitation).

**Tech Stack:** Ruby, RSpec, `net/http`, `mcp` gem (existing), `sqlite3` (existing), `json`, `digest`, `fileutils`, `open3`

**Design Doc:** `docs/plans/2026-02-15-remaining-layers-design.md`

---

## Conventions (all agents)

- `frozen_string_literal: true` on every file
- YARD docs on every public method and class
- Token estimation: `(string.length / 3.5).ceil`
- Error handling: `rescue StandardError`, never bare `rescue`
- Custom errors inherit from `CodebaseIndex::Error`
- Test commands: `bundle exec rspec spec/<dir>/ --format progress --format json --out tmp/test_results.json`
- Lint: `bundle exec rubocop <files>`
- Full suite verification: `bundle exec rspec --format progress --format json --out tmp/test_results.json`

---

## Wave 1

---

## Agent: chunking (Tasks 1-2)

**Backlog items:** B-053, B-054
**Owns:** `lib/codebase_index/chunking/`, `spec/chunking/`
**Reads (not modifies):** `lib/codebase_index/extracted_unit.rb`

### Task 1: Chunk value object

**Files:**
- Create: `lib/codebase_index/chunking/chunk.rb`
- Test: `spec/chunking/chunk_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/chunking/chunk_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/chunking/chunk'

RSpec.describe CodebaseIndex::Chunking::Chunk do
  let(:content) { "class User < ApplicationRecord\n  has_many :posts\nend" }

  subject(:chunk) do
    described_class.new(
      content: content,
      chunk_type: :associations,
      parent_identifier: 'User',
      parent_type: :model,
      metadata: { association_count: 1 }
    )
  end

  describe '#initialize' do
    it 'stores all attributes' do
      expect(chunk.content).to eq(content)
      expect(chunk.chunk_type).to eq(:associations)
      expect(chunk.parent_identifier).to eq('User')
      expect(chunk.parent_type).to eq(:model)
      expect(chunk.metadata).to eq({ association_count: 1 })
    end
  end

  describe '#token_count' do
    it 'estimates tokens from content length' do
      expect(chunk.token_count).to eq((content.length / 3.5).ceil)
    end
  end

  describe '#content_hash' do
    it 'computes SHA256 of content' do
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest(content))
    end
  end

  describe '#identifier' do
    it 'combines parent identifier and chunk type' do
      expect(chunk.identifier).to eq('User#associations')
    end
  end

  describe '#to_h' do
    it 'serializes all fields' do
      hash = chunk.to_h
      expect(hash[:content]).to eq(content)
      expect(hash[:chunk_type]).to eq(:associations)
      expect(hash[:parent_identifier]).to eq('User')
      expect(hash[:parent_type]).to eq(:model)
      expect(hash[:token_count]).to be_a(Integer)
      expect(hash[:content_hash]).to be_a(String)
      expect(hash[:identifier]).to eq('User#associations')
      expect(hash[:metadata]).to eq({ association_count: 1 })
    end
  end

  describe '#empty?' do
    it 'returns false when content has text' do
      expect(chunk).not_to be_empty
    end

    it 'returns true when content is blank' do
      blank_chunk = described_class.new(
        content: '  ',
        chunk_type: :summary,
        parent_identifier: 'User',
        parent_type: :model
      )
      expect(blank_chunk).to be_empty
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/chunking/chunk_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: FAIL — `cannot load such file -- codebase_index/chunking/chunk`

**Step 3: Write minimal implementation**

```ruby
# lib/codebase_index/chunking/chunk.rb
# frozen_string_literal: true

require 'digest'

module CodebaseIndex
  module Chunking
    # A single semantic chunk extracted from an ExtractedUnit.
    #
    # Chunks represent meaningful subsections of a code unit — associations,
    # callbacks, validations, individual actions, etc. Each chunk is independently
    # embeddable and retrievable, with a back-reference to its parent unit.
    #
    # @example
    #   chunk = Chunk.new(
    #     content: "has_many :posts\nhas_many :comments",
    #     chunk_type: :associations,
    #     parent_identifier: "User",
    #     parent_type: :model
    #   )
    #   chunk.token_count  # => 20
    #   chunk.identifier   # => "User#associations"
    #
    class Chunk
      attr_reader :content, :chunk_type, :parent_identifier, :parent_type, :metadata

      # @param content [String] The chunk's source code or text
      # @param chunk_type [Symbol] Semantic type (:summary, :associations, :callbacks, etc.)
      # @param parent_identifier [String] Identifier of the parent ExtractedUnit
      # @param parent_type [Symbol] Type of the parent unit (:model, :controller, etc.)
      # @param metadata [Hash] Optional chunk-specific metadata
      def initialize(content:, chunk_type:, parent_identifier:, parent_type:, metadata: {})
        @content = content
        @chunk_type = chunk_type
        @parent_identifier = parent_identifier
        @parent_type = parent_type
        @metadata = metadata
      end

      # Estimated token count using project convention.
      #
      # @return [Integer]
      def token_count
        @token_count ||= (content.length / 3.5).ceil
      end

      # SHA256 hash of content for change detection.
      #
      # @return [String]
      def content_hash
        @content_hash ||= Digest::SHA256.hexdigest(content)
      end

      # Unique identifier combining parent and chunk type.
      #
      # @return [String]
      def identifier
        "#{parent_identifier}##{chunk_type}"
      end

      # Whether the chunk has no meaningful content.
      #
      # @return [Boolean]
      def empty?
        content.nil? || content.strip.empty?
      end

      # Serialize to hash for JSON output.
      #
      # @return [Hash]
      def to_h
        {
          content: content,
          chunk_type: chunk_type,
          parent_identifier: parent_identifier,
          parent_type: parent_type,
          identifier: identifier,
          token_count: token_count,
          content_hash: content_hash,
          metadata: metadata
        }
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/chunking/chunk_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: 7 examples, 0 failures

**Step 5: Rubocop**

Run: `bundle exec rubocop lib/codebase_index/chunking/chunk.rb spec/chunking/chunk_spec.rb`
Expected: 0 offenses

---

### Task 2: SemanticChunker

**Files:**
- Create: `lib/codebase_index/chunking/semantic_chunker.rb`
- Test: `spec/chunking/semantic_chunker_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/chunking/semantic_chunker_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/chunking/semantic_chunker'
require 'codebase_index/extracted_unit'

RSpec.describe CodebaseIndex::Chunking::SemanticChunker do
  subject(:chunker) { described_class.new }

  let(:small_unit) do
    unit = CodebaseIndex::ExtractedUnit.new(
      type: :model,
      identifier: 'Tag',
      file_path: 'app/models/tag.rb'
    )
    unit.source_code = "class Tag < ApplicationRecord\nend"
    unit.metadata = {}
    unit
  end

  let(:large_model_unit) do
    unit = CodebaseIndex::ExtractedUnit.new(
      type: :model,
      identifier: 'User',
      file_path: 'app/models/user.rb'
    )
    # Build source with clear semantic sections
    unit.source_code = <<~RUBY
      class User < ApplicationRecord
        # Associations
        has_many :posts, dependent: :destroy
        has_many :comments, dependent: :destroy
        has_one :profile, dependent: :destroy
        belongs_to :organization, optional: true

        # Validations
        validates :email, presence: true, uniqueness: true
        validates :name, presence: true, length: { minimum: 2, maximum: 100 }
        validates :age, numericality: { greater_than: 0 }, allow_nil: true

        # Callbacks
        before_save :normalize_email
        after_create :send_welcome_email
        after_update :sync_profile, if: :name_changed?

        # Scopes
        scope :active, -> { where(active: true) }
        scope :admins, -> { where(role: 'admin') }
        scope :recent, -> { order(created_at: :desc) }

        def full_name
          [first_name, last_name].compact.join(' ')
        end

        def admin?
          role == 'admin'
        end

        private

        def normalize_email
          self.email = email.downcase.strip
        end

        def send_welcome_email
          UserMailer.welcome(self).deliver_later
        end

        def sync_profile
          profile&.update(name: name)
        end
      end
    RUBY
    unit.metadata = {
      'associations' => [
        { 'name' => 'posts', 'type' => 'has_many' },
        { 'name' => 'comments', 'type' => 'has_many' },
        { 'name' => 'profile', 'type' => 'has_one' },
        { 'name' => 'organization', 'type' => 'belongs_to' }
      ],
      'validations' => %w[email name age],
      'callbacks' => %w[before_save after_create after_update],
      'scopes' => %w[active admins recent]
    }
    unit
  end

  let(:controller_unit) do
    unit = CodebaseIndex::ExtractedUnit.new(
      type: :controller,
      identifier: 'PostsController',
      file_path: 'app/controllers/posts_controller.rb'
    )
    unit.source_code = <<~RUBY
      class PostsController < ApplicationController
        before_action :authenticate_user!
        before_action :set_post, only: [:show, :edit, :update, :destroy]

        def index
          @posts = Post.all.page(params[:page])
        end

        def show
        end

        def create
          @post = current_user.posts.build(post_params)
          if @post.save
            redirect_to @post, notice: 'Post created.'
          else
            render :new, status: :unprocessable_entity
          end
        end

        def update
          if @post.update(post_params)
            redirect_to @post, notice: 'Post updated.'
          else
            render :edit, status: :unprocessable_entity
          end
        end

        def destroy
          @post.destroy
          redirect_to posts_url, notice: 'Post deleted.'
        end

        private

        def set_post
          @post = Post.find(params[:id])
        end

        def post_params
          params.require(:post).permit(:title, :body)
        end
      end
    RUBY
    unit.metadata = {
      'actions' => %w[index show create update destroy],
      'before_actions' => %w[authenticate_user! set_post]
    }
    unit
  end

  describe '#chunk' do
    context 'with a small unit (under threshold)' do
      it 'returns a single whole-unit chunk' do
        chunks = chunker.chunk(small_unit)
        expect(chunks.size).to eq(1)
        expect(chunks.first.chunk_type).to eq(:whole)
        expect(chunks.first.content).to eq(small_unit.source_code)
        expect(chunks.first.parent_identifier).to eq('Tag')
      end
    end

    context 'with a large model' do
      it 'produces semantic chunks' do
        chunks = chunker.chunk(large_model_unit)
        chunk_types = chunks.map(&:chunk_type)
        expect(chunk_types).to include(:summary)
        expect(chunks.size).to be > 1
      end

      it 'includes a summary chunk with class declaration' do
        chunks = chunker.chunk(large_model_unit)
        summary = chunks.find { |c| c.chunk_type == :summary }
        expect(summary.content).to include('class User < ApplicationRecord')
      end

      it 'extracts association chunks when associations exist' do
        chunks = chunker.chunk(large_model_unit)
        assoc_chunk = chunks.find { |c| c.chunk_type == :associations }
        expect(assoc_chunk).not_to be_nil
        expect(assoc_chunk.content).to include('has_many :posts')
        expect(assoc_chunk.content).to include('belongs_to :organization')
      end

      it 'extracts validation chunks when validations exist' do
        chunks = chunker.chunk(large_model_unit)
        val_chunk = chunks.find { |c| c.chunk_type == :validations }
        expect(val_chunk).not_to be_nil
        expect(val_chunk.content).to include('validates :email')
      end

      it 'extracts callback chunks when callbacks exist' do
        chunks = chunker.chunk(large_model_unit)
        cb_chunk = chunks.find { |c| c.chunk_type == :callbacks }
        expect(cb_chunk).not_to be_nil
        expect(cb_chunk.content).to include('before_save')
      end

      it 'extracts scope chunks when scopes exist' do
        chunks = chunker.chunk(large_model_unit)
        scope_chunk = chunks.find { |c| c.chunk_type == :scopes }
        expect(scope_chunk).not_to be_nil
        expect(scope_chunk.content).to include('scope :active')
      end

      it 'extracts methods chunk' do
        chunks = chunker.chunk(large_model_unit)
        methods_chunk = chunks.find { |c| c.chunk_type == :methods }
        expect(methods_chunk).not_to be_nil
        expect(methods_chunk.content).to include('def full_name')
      end

      it 'sets parent_identifier on all chunks' do
        chunks = chunker.chunk(large_model_unit)
        chunks.each do |chunk|
          expect(chunk.parent_identifier).to eq('User')
          expect(chunk.parent_type).to eq(:model)
        end
      end
    end

    context 'with a controller' do
      it 'produces per-action chunks' do
        chunks = chunker.chunk(controller_unit)
        chunk_types = chunks.map(&:chunk_type)
        expect(chunk_types).to include(:summary)
        expect(chunk_types).to include(:action_index)
        expect(chunk_types).to include(:action_create)
      end

      it 'includes filters in the summary chunk' do
        chunks = chunker.chunk(controller_unit)
        summary = chunks.find { |c| c.chunk_type == :summary }
        expect(summary.content).to include('before_action')
      end

      it 'includes action code in action chunks' do
        chunks = chunker.chunk(controller_unit)
        create_chunk = chunks.find { |c| c.chunk_type == :action_create }
        expect(create_chunk.content).to include('def create')
        expect(create_chunk.content).to include('post_params')
      end
    end

    context 'with a service (generic unit)' do
      let(:service_unit) do
        unit = CodebaseIndex::ExtractedUnit.new(
          type: :service,
          identifier: 'PaymentProcessor',
          file_path: 'app/services/payment_processor.rb'
        )
        unit.source_code = "class PaymentProcessor\n  def call(order)\n    # process\n  end\nend"
        unit.metadata = {}
        unit
      end

      it 'returns whole-unit chunk for small services' do
        chunks = chunker.chunk(service_unit)
        expect(chunks.size).to eq(1)
        expect(chunks.first.chunk_type).to eq(:whole)
      end
    end

    context 'with nil source_code' do
      it 'returns empty array' do
        unit = CodebaseIndex::ExtractedUnit.new(
          type: :model,
          identifier: 'Empty',
          file_path: 'app/models/empty.rb'
        )
        chunks = chunker.chunk(unit)
        expect(chunks).to eq([])
      end
    end
  end

  describe '#chunk with custom threshold' do
    subject(:chunker) { described_class.new(threshold: 50) }

    it 'respects the custom threshold' do
      chunks = chunker.chunk(small_unit)
      # With threshold of 50 tokens, even small units might stay whole
      expect(chunks).to all(be_a(CodebaseIndex::Chunking::Chunk))
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/chunking/semantic_chunker_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: FAIL

**Step 3: Write implementation**

```ruby
# lib/codebase_index/chunking/semantic_chunker.rb
# frozen_string_literal: true

require_relative 'chunk'

module CodebaseIndex
  module Chunking
    # Splits ExtractedUnits into semantic chunks based on unit type.
    #
    # Models are split by: summary, associations, validations, callbacks,
    # scopes, methods. Controllers are split by: summary (filters), per-action.
    # Other types use whole-unit or method-level splitting based on size.
    #
    # Units below the token threshold are returned as a single :whole chunk.
    #
    # @example
    #   chunker = SemanticChunker.new(threshold: 200)
    #   chunks = chunker.chunk(extracted_unit)
    #   chunks.map(&:chunk_type) # => [:summary, :associations, :validations, :methods]
    #
    class SemanticChunker
      # Regex patterns for detecting semantic boundaries in Ruby source
      ASSOCIATION_PATTERN = /^\s*(has_many|has_one|belongs_to|has_and_belongs_to_many)\b/.freeze
      VALIDATION_PATTERN = /^\s*validates?\b/.freeze
      CALLBACK_PATTERN = /^\s*(before_|after_|around_)(save|create|update|destroy|validation|action|commit|rollback|find|initialize|touch)\b/.freeze
      SCOPE_PATTERN = /^\s*scope\s+:/.freeze
      FILTER_PATTERN = /^\s*(before_action|after_action|around_action|skip_before_action)\b/.freeze
      METHOD_PATTERN = /^\s*def\s+/.freeze
      PRIVATE_PATTERN = /^\s*(private|protected)\s*$/.freeze

      # Default token threshold below which units stay whole.
      DEFAULT_THRESHOLD = 200

      # @param threshold [Integer] Token count threshold for chunking
      def initialize(threshold: DEFAULT_THRESHOLD)
        @threshold = threshold
      end

      # Split an ExtractedUnit into semantic chunks.
      #
      # @param unit [ExtractedUnit] The unit to chunk
      # @return [Array<Chunk>] Ordered list of chunks
      def chunk(unit)
        return [] if unit.source_code.nil? || unit.source_code.strip.empty?

        if unit.estimated_tokens <= @threshold
          return [build_whole_chunk(unit)]
        end

        case unit.type
        when :model
          chunk_model(unit)
        when :controller
          chunk_controller(unit)
        else
          chunk_generic(unit)
        end
      end

      private

      # Build a single :whole chunk for small units.
      #
      # @param unit [ExtractedUnit]
      # @return [Chunk]
      def build_whole_chunk(unit)
        Chunk.new(
          content: unit.source_code,
          chunk_type: :whole,
          parent_identifier: unit.identifier,
          parent_type: unit.type
        )
      end

      # Chunk a model by semantic sections.
      #
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def chunk_model(unit)
        lines = unit.source_code.lines
        sections = classify_model_lines(lines)

        chunks = []

        # Summary: class declaration + any non-categorized header lines
        summary_lines = sections[:summary]
        if summary_lines.any?
          chunks << build_chunk(unit, :summary, summary_lines.join)
        end

        # Each semantic section
        { associations: sections[:associations],
          validations: sections[:validations],
          callbacks: sections[:callbacks],
          scopes: sections[:scopes] }.each do |type, section_lines|
          next if section_lines.empty?

          chunks << build_chunk(unit, type, section_lines.join)
        end

        # Methods (public + private)
        method_lines = sections[:methods]
        if method_lines.any?
          chunks << build_chunk(unit, :methods, method_lines.join)
        end

        chunks.reject(&:empty?)
      end

      # Classify each line of a model into semantic sections.
      #
      # @param lines [Array<String>]
      # @return [Hash<Symbol, Array<String>>]
      def classify_model_lines(lines)
        sections = {
          summary: [],
          associations: [],
          validations: [],
          callbacks: [],
          scopes: [],
          methods: []
        }

        current_section = :summary
        in_method = false
        method_depth = 0

        lines.each do |line|
          if in_method
            sections[:methods] << line
            method_depth += 1 if line.match?(/\bdo\b|\bdef\b/) && !line.match?(/\bend\b/)
            method_depth -= 1 if line.strip == 'end' || (line.match?(/\bend\s*$/) && method_depth.positive?)
            in_method = false if method_depth <= 0 && line.strip.match?(/^end\s*$/)
            next
          end

          case line
          when ASSOCIATION_PATTERN
            current_section = :associations
            sections[:associations] << line
          when VALIDATION_PATTERN
            current_section = :validations
            sections[:validations] << line
          when CALLBACK_PATTERN
            current_section = :callbacks
            sections[:callbacks] << line
          when SCOPE_PATTERN
            current_section = :scopes
            sections[:scopes] << line
          when PRIVATE_PATTERN
            sections[:methods] << line
          when METHOD_PATTERN
            in_method = true
            method_depth = 1
            sections[:methods] << line
          else
            # Continuation lines stay with current section, or go to summary
            if current_section == :summary || line.strip.empty? || line.match?(/^\s*#/)
              sections[:summary] << line
            else
              sections[current_section] << line
            end
          end
        end

        sections
      end

      # Chunk a controller by actions.
      #
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def chunk_controller(unit)
        lines = unit.source_code.lines
        chunks = []

        # Summary: class declaration + filters
        summary_lines = []
        action_buffers = {}
        current_action = nil
        action_depth = 0
        in_private = false

        lines.each do |line|
          if current_action
            action_buffers[current_action] << line
            action_depth += 1 if line.match?(/\bdo\b/) && !line.match?(/\bend\b/)
            if line.strip.match?(/^end\s*$/)
              action_depth -= 1
              if action_depth <= 0
                current_action = nil
                action_depth = 0
              end
            end
            next
          end

          if line.match?(PRIVATE_PATTERN)
            in_private = true
            summary_lines << line
            next
          end

          if !in_private && line.match?(METHOD_PATTERN)
            action_name = line[/def\s+(\w+)/, 1]
            current_action = action_name
            action_depth = 1
            action_buffers[action_name] = [line]
          elsif line.match?(FILTER_PATTERN) || line.match?(/^\s*class\b/) || line.strip.empty? || line.match?(/^\s*#/)
            summary_lines << line
          else
            summary_lines << line
          end
        end

        # Build summary chunk
        if summary_lines.any?
          chunks << build_chunk(unit, :summary, summary_lines.join)
        end

        # Build per-action chunks
        action_buffers.each do |action_name, action_lines|
          chunks << build_chunk(unit, :"action_#{action_name}", action_lines.join)
        end

        chunks.reject(&:empty?)
      end

      # Chunk a generic unit (service, job, mailer, etc).
      #
      # @param unit [ExtractedUnit]
      # @return [Array<Chunk>]
      def chunk_generic(unit)
        # For generic types, just return as whole chunk
        # (method-level splitting for very large units could be added later)
        [build_whole_chunk(unit)]
      end

      # Build a Chunk with standard attributes.
      #
      # @param unit [ExtractedUnit]
      # @param chunk_type [Symbol]
      # @param content [String]
      # @return [Chunk]
      def build_chunk(unit, chunk_type, content)
        Chunk.new(
          content: content,
          chunk_type: chunk_type,
          parent_identifier: unit.identifier,
          parent_type: unit.type
        )
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/chunking/semantic_chunker_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: All examples pass

**Step 5: Full suite + rubocop**

Run: `bundle exec rspec --format progress --format json --out tmp/test_results.json`
Run: `bundle exec rubocop lib/codebase_index/chunking/ spec/chunking/`
Expected: Full suite green, 0 rubocop offenses

---

## Agent: schema (Tasks 3-6)

**Backlog items:** B-055, B-056
**Owns:** `lib/generators/codebase_index/`, `lib/codebase_index/db/`, `spec/db/`, `spec/generators/`

### Task 3: SchemaVersion — tracking applied migrations

**Files:**
- Create: `lib/codebase_index/db/schema_version.rb`
- Test: `spec/db/schema_version_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/db/schema_version_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/db/schema_version'
require 'sqlite3'

RSpec.describe CodebaseIndex::Db::SchemaVersion do
  let(:db) { SQLite3::Database.new(':memory:') }

  subject(:schema_version) { described_class.new(connection: db) }

  describe '#ensure_table!' do
    it 'creates the schema_migrations table' do
      schema_version.ensure_table!
      result = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='codebase_index_schema_migrations'")
      expect(result).not_to be_empty
    end

    it 'is idempotent' do
      schema_version.ensure_table!
      schema_version.ensure_table!
      result = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='codebase_index_schema_migrations'")
      expect(result.size).to eq(1)
    end
  end

  describe '#applied_versions' do
    before { schema_version.ensure_table! }

    it 'returns empty array when no migrations applied' do
      expect(schema_version.applied_versions).to eq([])
    end

    it 'returns applied version numbers sorted' do
      schema_version.record_version(2)
      schema_version.record_version(1)
      expect(schema_version.applied_versions).to eq([1, 2])
    end
  end

  describe '#record_version' do
    before { schema_version.ensure_table! }

    it 'records a version number' do
      schema_version.record_version(1)
      expect(schema_version.applied_versions).to include(1)
    end

    it 'does not duplicate versions' do
      schema_version.record_version(1)
      schema_version.record_version(1)
      expect(schema_version.applied_versions.count(1)).to eq(1)
    end
  end

  describe '#applied?' do
    before { schema_version.ensure_table! }

    it 'returns true for applied versions' do
      schema_version.record_version(1)
      expect(schema_version.applied?(1)).to be true
    end

    it 'returns false for unapplied versions' do
      expect(schema_version.applied?(99)).to be false
    end
  end

  describe '#current_version' do
    before { schema_version.ensure_table! }

    it 'returns 0 when no migrations applied' do
      expect(schema_version.current_version).to eq(0)
    end

    it 'returns the highest applied version' do
      schema_version.record_version(1)
      schema_version.record_version(3)
      expect(schema_version.current_version).to eq(3)
    end
  end
end
```

**Step 2:** Run test — expected fail (cannot load file)

**Step 3: Write implementation**

```ruby
# lib/codebase_index/db/schema_version.rb
# frozen_string_literal: true

module CodebaseIndex
  module Db
    # Tracks which schema migrations have been applied.
    #
    # Uses a simple `codebase_index_schema_migrations` table with a single
    # `version` column. Works with any database connection that supports
    # `execute` and returns arrays (SQLite3, pg, mysql2).
    #
    # @example
    #   db = SQLite3::Database.new('codebase_index.db')
    #   sv = SchemaVersion.new(connection: db)
    #   sv.ensure_table!
    #   sv.current_version  # => 0
    #   sv.record_version(1)
    #   sv.current_version  # => 1
    #
    class SchemaVersion
      TABLE_NAME = 'codebase_index_schema_migrations'

      # @param connection [Object] Database connection supporting #execute
      def initialize(connection:)
        @connection = connection
      end

      # Create the schema migrations table if it does not exist.
      #
      # @return [void]
      def ensure_table!
        @connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
            version INTEGER PRIMARY KEY NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
          )
        SQL
      end

      # List all applied migration version numbers, sorted ascending.
      #
      # @return [Array<Integer>]
      def applied_versions
        rows = @connection.execute("SELECT version FROM #{TABLE_NAME} ORDER BY version ASC")
        rows.map { |row| row.is_a?(Array) ? row[0] : row['version'] }
      end

      # Record a migration version as applied.
      #
      # @param version [Integer] The migration version number
      # @return [void]
      def record_version(version)
        @connection.execute(
          "INSERT OR IGNORE INTO #{TABLE_NAME} (version) VALUES (?)", [version]
        )
      end

      # Check whether a version has been applied.
      #
      # @param version [Integer]
      # @return [Boolean]
      def applied?(version)
        applied_versions.include?(version)
      end

      # The highest applied version, or 0 if none.
      #
      # @return [Integer]
      def current_version
        applied_versions.last || 0
      end
    end
  end
end
```

**Step 4:** Run test — expected pass
**Step 5:** Rubocop

---

### Task 4: Migrator — standalone migration runner

**Files:**
- Create: `lib/codebase_index/db/migrator.rb`
- Create: `lib/codebase_index/db/migrations/001_create_units.rb`
- Create: `lib/codebase_index/db/migrations/002_create_edges.rb`
- Create: `lib/codebase_index/db/migrations/003_create_embeddings.rb`
- Test: `spec/db/migrator_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/db/migrator_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/db/migrator'
require 'sqlite3'

RSpec.describe CodebaseIndex::Db::Migrator do
  let(:db) { SQLite3::Database.new(':memory:') }

  subject(:migrator) { described_class.new(connection: db) }

  describe '#migrate!' do
    it 'creates codebase_units table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('codebase_units')
    end

    it 'creates codebase_edges table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('codebase_edges')
    end

    it 'creates codebase_embeddings table' do
      migrator.migrate!
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('codebase_embeddings')
    end

    it 'records applied versions' do
      migrator.migrate!
      expect(migrator.schema_version.applied_versions).to eq([1, 2, 3])
    end

    it 'is idempotent — skips already-applied migrations' do
      migrator.migrate!
      # Should not raise on second run
      migrator.migrate!
      expect(migrator.schema_version.applied_versions).to eq([1, 2, 3])
    end

    it 'returns list of newly applied version numbers' do
      result = migrator.migrate!
      expect(result).to eq([1, 2, 3])

      # Second run applies nothing
      result2 = migrator.migrate!
      expect(result2).to eq([])
    end
  end

  describe '#pending_versions' do
    it 'returns all versions when none applied' do
      expect(migrator.pending_versions).to eq([1, 2, 3])
    end

    it 'returns only unapplied versions' do
      migrator.migrate!
      expect(migrator.pending_versions).to eq([])
    end
  end

  describe 'codebase_units schema' do
    before { migrator.migrate! }

    it 'has expected columns' do
      columns = db.execute("PRAGMA table_info(codebase_units)").map { |c| c[1] }
      expect(columns).to include('id', 'unit_type', 'identifier', 'namespace',
                                  'file_path', 'source_code', 'source_hash', 'metadata')
    end

    it 'enforces unique identifier' do
      db.execute("INSERT INTO codebase_units (unit_type, identifier, file_path) VALUES ('model', 'User', 'app/models/user.rb')")
      expect do
        db.execute("INSERT INTO codebase_units (unit_type, identifier, file_path) VALUES ('model', 'User', 'app/models/user.rb')")
      end.to raise_error(SQLite3::ConstraintException)
    end
  end

  describe 'codebase_edges schema' do
    before { migrator.migrate! }

    it 'has expected columns' do
      columns = db.execute("PRAGMA table_info(codebase_edges)").map { |c| c[1] }
      expect(columns).to include('id', 'source_id', 'target_id', 'relationship', 'via')
    end
  end
end
```

**Step 2:** Run test — expected fail

**Step 3: Write migrations and migrator**

```ruby
# lib/codebase_index/db/migrations/001_create_units.rb
# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_units table for storing extracted unit metadata.
      module CreateUnits
        VERSION = 1

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_units (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_type TEXT NOT NULL,
              identifier TEXT NOT NULL,
              namespace TEXT,
              file_path TEXT NOT NULL,
              source_code TEXT,
              source_hash TEXT,
              metadata TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              updated_at TEXT NOT NULL DEFAULT (datetime('now')),
              UNIQUE(identifier)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_units_type ON codebase_units(unit_type)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_units_file_path ON codebase_units(file_path)
          SQL
        end
      end
    end
  end
end
```

```ruby
# lib/codebase_index/db/migrations/002_create_edges.rb
# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_edges table for storing unit relationships.
      module CreateEdges
        VERSION = 2

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_edges (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_id INTEGER NOT NULL,
              target_id INTEGER NOT NULL,
              relationship TEXT NOT NULL,
              via TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (source_id) REFERENCES codebase_units(id),
              FOREIGN KEY (target_id) REFERENCES codebase_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_edges_source ON codebase_edges(source_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_edges_target ON codebase_edges(target_id)
          SQL
        end
      end
    end
  end
end
```

```ruby
# lib/codebase_index/db/migrations/003_create_embeddings.rb
# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_embeddings table for storing vector embeddings.
      # Uses TEXT for embedding storage (JSON array) for database portability.
      # Pgvector users should use the pgvector generator for native vector columns.
      module CreateEmbeddings
        VERSION = 3

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_embeddings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id INTEGER NOT NULL,
              chunk_type TEXT,
              embedding TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              dimensions INTEGER NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (unit_id) REFERENCES codebase_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_embeddings_unit ON codebase_embeddings(unit_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_embeddings_hash ON codebase_embeddings(content_hash)
          SQL
        end
      end
    end
  end
end
```

```ruby
# lib/codebase_index/db/migrator.rb
# frozen_string_literal: true

require_relative 'schema_version'
require_relative 'migrations/001_create_units'
require_relative 'migrations/002_create_edges'
require_relative 'migrations/003_create_embeddings'

module CodebaseIndex
  module Db
    # Runs schema migrations against a database connection.
    #
    # Tracks applied migrations via {SchemaVersion} and only runs pending ones.
    # Migrations are defined as modules in `db/migrations/` with a VERSION
    # constant and a `.up(connection)` class method.
    #
    # @example
    #   db = SQLite3::Database.new('codebase_index.db')
    #   migrator = Migrator.new(connection: db)
    #   migrator.migrate!  # => [1, 2, 3]
    #
    class Migrator
      MIGRATIONS = [
        Migrations::CreateUnits,
        Migrations::CreateEdges,
        Migrations::CreateEmbeddings
      ].freeze

      attr_reader :schema_version

      # @param connection [Object] Database connection supporting #execute
      def initialize(connection:)
        @connection = connection
        @schema_version = SchemaVersion.new(connection: connection)
        @schema_version.ensure_table!
      end

      # Run all pending migrations.
      #
      # @return [Array<Integer>] Version numbers of newly applied migrations
      def migrate!
        applied = []
        pending_migrations.each do |migration|
          migration.up(@connection)
          @schema_version.record_version(migration::VERSION)
          applied << migration::VERSION
        end
        applied
      end

      # List version numbers of pending (unapplied) migrations.
      #
      # @return [Array<Integer>]
      def pending_versions
        applied = @schema_version.applied_versions
        MIGRATIONS.map { |m| m::VERSION }.reject { |v| applied.include?(v) }
      end

      private

      # @return [Array<Module>] Pending migration modules
      def pending_migrations
        applied = @schema_version.applied_versions
        MIGRATIONS.reject { |m| applied.include?(m::VERSION) }
      end
    end
  end
end
```

**Step 4:** Run test — expected pass
**Step 5:** Rubocop

---

### Task 5: Rails install generator

**Files:**
- Create: `lib/generators/codebase_index/install_generator.rb`
- Create: `lib/generators/codebase_index/templates/create_codebase_index_tables.rb.erb`
- Test: `spec/generators/install_generator_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/generators/install_generator_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'codebase_index/db/migrator'

# Test the generator template output without Rails generators framework
RSpec.describe 'Install generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/codebase_index/templates/create_codebase_index_tables.rb.erb', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'template contains CreateCodebaseIndexTables class' do
    content = File.read(template_path)
    expect(content).to include('class CreateCodebaseIndexTables')
  end

  it 'template creates codebase_units table' do
    content = File.read(template_path)
    expect(content).to include('create_table :codebase_units')
  end

  it 'template creates codebase_edges table' do
    content = File.read(template_path)
    expect(content).to include('create_table :codebase_edges')
  end

  it 'template creates codebase_embeddings table' do
    content = File.read(template_path)
    expect(content).to include('create_table :codebase_embeddings')
  end

  it 'template includes indexes' do
    content = File.read(template_path)
    expect(content).to include('add_index :codebase_units')
    expect(content).to include('add_index :codebase_edges')
  end
end

RSpec.describe 'Install generator class' do
  let(:generator_path) do
    File.expand_path('../../lib/generators/codebase_index/install_generator.rb', __dir__)
  end

  it 'generator file exists' do
    expect(File.exist?(generator_path)).to be true
  end

  it 'defines CodebaseIndex::Generators::InstallGenerator' do
    content = File.read(generator_path)
    expect(content).to include('class InstallGenerator')
    expect(content).to include('module Generators')
  end
end
```

**Step 2:** Run test — expected fail

**Step 3: Write generator and template**

```ruby
# lib/generators/codebase_index/install_generator.rb
# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module CodebaseIndex
  module Generators
    # Rails generator that creates a migration for CodebaseIndex tables.
    #
    # Usage:
    #   rails generate codebase_index:install
    #
    # Creates a migration with codebase_units, codebase_edges, and
    # codebase_embeddings tables. Works with PostgreSQL, MySQL, and SQLite.
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a migration for CodebaseIndex tables (units, edges, embeddings)'

      # @return [void]
      def create_migration_file
        migration_template(
          'create_codebase_index_tables.rb.erb',
          'db/migrate/create_codebase_index_tables.rb'
        )
      end
    end
  end
end
```

```erb
# lib/generators/codebase_index/templates/create_codebase_index_tables.rb.erb
class CreateCodebaseIndexTables < ActiveRecord::Migration[7.0]
  def change
    create_table :codebase_units do |t|
      t.string :unit_type, null: false
      t.string :identifier, null: false
      t.string :namespace
      t.string :file_path, null: false
      t.text :source_code
      t.string :source_hash
      t.json :metadata

      t.timestamps
    end

    add_index :codebase_units, :unit_type
    add_index :codebase_units, :identifier, unique: true
    add_index :codebase_units, :file_path

    create_table :codebase_edges do |t|
      t.references :source, null: false, foreign_key: { to_table: :codebase_units }
      t.references :target, null: false, foreign_key: { to_table: :codebase_units }
      t.string :relationship, null: false
      t.string :via

      t.datetime :created_at, null: false
    end

    add_index :codebase_edges, [:source_id, :target_id, :relationship], unique: true,
              name: 'idx_codebase_edges_unique'

    create_table :codebase_embeddings do |t|
      t.references :unit, null: false, foreign_key: { to_table: :codebase_units }
      t.string :chunk_type
      t.text :embedding, null: false
      t.string :content_hash, null: false
      t.integer :dimensions, null: false

      t.datetime :created_at, null: false
    end

    add_index :codebase_embeddings, :content_hash
  end
end
```

**Step 4:** Run test — expected pass
**Step 5:** Rubocop

---

### Task 6: Pgvector generator

**Files:**
- Create: `lib/generators/codebase_index/pgvector_generator.rb`
- Create: `lib/generators/codebase_index/templates/add_pgvector_to_codebase_index.rb.erb`
- Test: `spec/generators/pgvector_generator_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/generators/pgvector_generator_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pgvector generator template' do
  let(:template_path) do
    File.expand_path('../../lib/generators/codebase_index/templates/add_pgvector_to_codebase_index.rb.erb', __dir__)
  end

  it 'template file exists' do
    expect(File.exist?(template_path)).to be true
  end

  it 'enables pgvector extension' do
    content = File.read(template_path)
    expect(content).to include('enable_extension')
    expect(content).to include('vector')
  end

  it 'adds vector column to codebase_embeddings' do
    content = File.read(template_path)
    expect(content).to include('codebase_embeddings')
    expect(content).to include('embedding_vector')
  end

  it 'creates HNSW index' do
    content = File.read(template_path)
    expect(content).to match(/hnsw|ivfflat/i)
  end
end

RSpec.describe 'Pgvector generator class' do
  let(:generator_path) do
    File.expand_path('../../lib/generators/codebase_index/pgvector_generator.rb', __dir__)
  end

  it 'generator file exists' do
    expect(File.exist?(generator_path)).to be true
  end

  it 'defines PgvectorGenerator' do
    content = File.read(generator_path)
    expect(content).to include('class PgvectorGenerator')
  end
end
```

**Step 2:** Run — fail
**Step 3: Write generator and template**

```ruby
# lib/generators/codebase_index/pgvector_generator.rb
# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module CodebaseIndex
  module Generators
    # Rails generator that adds pgvector support to CodebaseIndex.
    #
    # Requires the pgvector PostgreSQL extension. Adds a native vector column
    # and HNSW index to the codebase_embeddings table.
    #
    # Usage:
    #   rails generate codebase_index:pgvector
    #   rails generate codebase_index:pgvector --dimensions 3072
    #
    class PgvectorGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Adds pgvector native vector column and HNSW index to codebase_embeddings'

      class_option :dimensions, type: :numeric, default: 1536,
                                desc: 'Vector dimensions (1536 for text-embedding-3-small, 3072 for large)'

      # @return [void]
      def create_migration_file
        @dimensions = options[:dimensions]
        migration_template(
          'add_pgvector_to_codebase_index.rb.erb',
          'db/migrate/add_pgvector_to_codebase_index.rb'
        )
      end
    end
  end
end
```

```erb
# lib/generators/codebase_index/templates/add_pgvector_to_codebase_index.rb.erb
class AddPgvectorToCodebaseIndex < ActiveRecord::Migration[7.0]
  def change
    enable_extension 'vector' unless extension_enabled?('vector')

    add_column :codebase_embeddings, :embedding_vector, :vector,
               limit: <%= @dimensions || 1536 %>, null: true

    # HNSW index for fast approximate nearest neighbor search
    # Using cosine distance operator (vector_cosine_ops)
    add_index :codebase_embeddings, :embedding_vector,
              using: :hnsw,
              opclass: :vector_cosine_ops,
              name: 'idx_codebase_embeddings_vector_hnsw'
  end
end
```

**Step 4:** Run — pass
**Step 5:** Full suite + rubocop

---

## Agent: agentic (Tasks 7-14)

**Backlog items:** B-057
**Owns:** `lib/codebase_index/operator/`, `lib/codebase_index/coordination/`, `lib/codebase_index/feedback/`, `spec/operator/`, `spec/coordination/`, `spec/feedback/`
**Modifies:** `lib/codebase_index/mcp/server.rb`, `spec/mcp/server_spec.rb`, `lib/codebase_index/retriever.rb`, `spec/retriever_spec.rb`

### Task 7: PipelineLock — file-based locking

**Files:**
- Create: `lib/codebase_index/coordination/pipeline_lock.rb`
- Test: `spec/coordination/pipeline_lock_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/coordination/pipeline_lock_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'codebase_index/coordination/pipeline_lock'

RSpec.describe CodebaseIndex::Coordination::PipelineLock do
  let(:lock_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(lock_dir) }

  subject(:lock) { described_class.new(lock_dir: lock_dir, name: 'extraction') }

  describe '#acquire' do
    it 'creates a lock file' do
      lock.acquire
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be true
    end

    it 'returns true on successful acquisition' do
      expect(lock.acquire).to be true
    end

    it 'returns false if already locked' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect(other_lock.acquire).to be false
    end
  end

  describe '#release' do
    it 'removes the lock file' do
      lock.acquire
      lock.release
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be false
    end

    it 'does not raise if not locked' do
      expect { lock.release }.not_to raise_error
    end
  end

  describe '#with_lock' do
    it 'yields the block when lock acquired' do
      result = lock.with_lock { 42 }
      expect(result).to eq(42)
    end

    it 'releases lock after block completes' do
      lock.with_lock { 'work' }
      expect(lock.locked?).to be false
    end

    it 'releases lock on exception' do
      begin
        lock.with_lock { raise 'boom' }
      rescue RuntimeError
        nil
      end
      expect(lock.locked?).to be false
    end

    it 'raises LockError when lock unavailable' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect do
        other_lock.with_lock { 'work' }
      end.to raise_error(CodebaseIndex::Coordination::LockError)
    end
  end

  describe '#locked?' do
    it 'returns false when not locked' do
      expect(lock.locked?).to be false
    end

    it 'returns true when locked' do
      lock.acquire
      expect(lock.locked?).to be true
    end
  end

  describe 'stale lock detection' do
    it 'treats locks older than timeout as stale' do
      lock.acquire
      lock_path = File.join(lock_dir, 'extraction.lock')
      # Backdate the lock file
      FileUtils.touch(lock_path, mtime: Time.now - 3600)

      stale_lock = described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 1800)
      expect(stale_lock.acquire).to be true
    end
  end
end
```

**Step 2:** Run — fail

**Step 3: Write implementation**

```ruby
# lib/codebase_index/coordination/pipeline_lock.rb
# frozen_string_literal: true

require 'fileutils'
require 'json'

module CodebaseIndex
  module Coordination
    class LockError < CodebaseIndex::Error; end

    # File-based lock for preventing concurrent pipeline operations.
    #
    # Creates a lock file with PID and timestamp. Supports stale lock
    # detection for crashed processes.
    #
    # @example
    #   lock = PipelineLock.new(lock_dir: '/tmp', name: 'extraction')
    #   lock.with_lock do
    #     # extraction runs here
    #   end
    #
    class PipelineLock
      DEFAULT_STALE_TIMEOUT = 3600 # 1 hour

      # @param lock_dir [String] Directory for lock files
      # @param name [String] Lock name (used as filename prefix)
      # @param stale_timeout [Integer] Seconds after which a lock is considered stale
      def initialize(lock_dir:, name:, stale_timeout: DEFAULT_STALE_TIMEOUT)
        @lock_dir = lock_dir
        @name = name
        @stale_timeout = stale_timeout
        @lock_path = File.join(lock_dir, "#{name}.lock")
        @held = false
      end

      # Attempt to acquire the lock.
      #
      # @return [Boolean] true if lock acquired, false if already held
      def acquire
        FileUtils.mkdir_p(@lock_dir)

        if File.exist?(@lock_path)
          return false unless stale?

          # Remove stale lock
          FileUtils.rm_f(@lock_path)
        end

        # Write lock file atomically
        File.write(@lock_path, lock_content)
        @held = true
        true
      rescue Errno::EEXIST
        false
      end

      # Release the lock.
      #
      # @return [void]
      def release
        FileUtils.rm_f(@lock_path) if @held
        @held = false
      end

      # Execute a block while holding the lock.
      #
      # @yield Block to execute
      # @return [Object] Return value of the block
      # @raise [LockError] if lock cannot be acquired
      def with_lock(&block)
        raise LockError, "Cannot acquire lock '#{@name}' — another process is running" unless acquire

        begin
          block.call
        ensure
          release
        end
      end

      # Whether the lock is currently held by this instance.
      #
      # @return [Boolean]
      def locked?
        @held && File.exist?(@lock_path)
      end

      private

      # Check if the existing lock file is stale.
      #
      # @return [Boolean]
      def stale?
        return false unless File.exist?(@lock_path)

        age = Time.now - File.mtime(@lock_path)
        age > @stale_timeout
      end

      # @return [String] Lock file content (JSON with PID and timestamp)
      def lock_content
        JSON.generate(pid: Process.pid, locked_at: Time.now.iso8601, name: @name)
      end
    end
  end
end
```

**Step 4:** Run — pass
**Step 5:** Rubocop

---

### Task 8: FeedbackStore — JSONL feedback storage

**Files:**
- Create: `lib/codebase_index/feedback/store.rb`
- Test: `spec/feedback/store_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/feedback/store_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'codebase_index/feedback/store'

RSpec.describe CodebaseIndex::Feedback::Store do
  let(:feedback_dir) { Dir.mktmpdir }
  let(:feedback_path) { File.join(feedback_dir, 'feedback.jsonl') }

  after { FileUtils.rm_rf(feedback_dir) }

  subject(:store) { described_class.new(path: feedback_path) }

  describe '#record_rating' do
    it 'appends a rating entry to the JSONL file' do
      store.record_rating(query: 'How does User work?', score: 4, comment: 'Good')
      entries = store.all_entries
      expect(entries.size).to eq(1)
      expect(entries.first['type']).to eq('rating')
      expect(entries.first['score']).to eq(4)
      expect(entries.first['query']).to eq('How does User work?')
    end

    it 'appends multiple entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_rating(query: 'q2', score: 5)
      expect(store.all_entries.size).to eq(2)
    end

    it 'includes timestamp' do
      store.record_rating(query: 'q', score: 4)
      expect(store.all_entries.first['timestamp']).not_to be_nil
    end
  end

  describe '#record_gap' do
    it 'appends a gap report entry' do
      store.record_gap(query: 'What about payments?', missing_unit: 'PaymentService', unit_type: 'service')
      entries = store.all_entries
      expect(entries.size).to eq(1)
      expect(entries.first['type']).to eq('gap')
      expect(entries.first['missing_unit']).to eq('PaymentService')
    end
  end

  describe '#all_entries' do
    it 'returns empty array when file does not exist' do
      new_store = described_class.new(path: File.join(feedback_dir, 'nonexistent.jsonl'))
      expect(new_store.all_entries).to eq([])
    end
  end

  describe '#ratings' do
    it 'filters to only rating entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_gap(query: 'q2', missing_unit: 'X', unit_type: 'service')
      store.record_rating(query: 'q3', score: 5)
      expect(store.ratings.size).to eq(2)
    end
  end

  describe '#gaps' do
    it 'filters to only gap entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_gap(query: 'q2', missing_unit: 'X', unit_type: 'service')
      expect(store.gaps.size).to eq(1)
    end
  end

  describe '#average_score' do
    it 'computes mean of all rating scores' do
      store.record_rating(query: 'q1', score: 2)
      store.record_rating(query: 'q2', score: 4)
      expect(store.average_score).to eq(3.0)
    end

    it 'returns nil when no ratings' do
      expect(store.average_score).to be_nil
    end
  end
end
```

**Step 2:** Run — fail

**Step 3: Write implementation**

```ruby
# lib/codebase_index/feedback/store.rb
# frozen_string_literal: true

require 'json'
require 'fileutils'

module CodebaseIndex
  module Feedback
    # Append-only JSONL file for retrieval feedback: ratings and gap reports.
    #
    # Each line is a JSON object with a `type` field ("rating" or "gap")
    # plus type-specific fields.
    #
    # @example
    #   store = Store.new(path: '/tmp/feedback.jsonl')
    #   store.record_rating(query: "How does User work?", score: 4)
    #   store.record_gap(query: "payments", missing_unit: "PaymentService", unit_type: "service")
    #   store.average_score  # => 4.0
    #
    class Store
      # @param path [String] Path to the JSONL file
      def initialize(path:)
        @path = path
      end

      # Record a retrieval quality rating.
      #
      # @param query [String] The original query
      # @param score [Integer] Rating 1-5
      # @param comment [String, nil] Optional comment
      # @return [void]
      def record_rating(query:, score:, comment: nil)
        entry = {
          type: 'rating',
          query: query,
          score: score,
          comment: comment,
          timestamp: Time.now.iso8601
        }
        append(entry)
      end

      # Record a missing unit gap report.
      #
      # @param query [String] The query that had poor results
      # @param missing_unit [String] Identifier of the expected but missing unit
      # @param unit_type [String] Expected type of the missing unit
      # @return [void]
      def record_gap(query:, missing_unit:, unit_type:)
        entry = {
          type: 'gap',
          query: query,
          missing_unit: missing_unit,
          unit_type: unit_type,
          timestamp: Time.now.iso8601
        }
        append(entry)
      end

      # Read all feedback entries.
      #
      # @return [Array<Hash>]
      def all_entries
        return [] unless File.exist?(@path)

        File.readlines(@path).filter_map do |line|
          JSON.parse(line.strip) unless line.strip.empty?
        rescue JSON::ParserError
          nil
        end
      end

      # Filter to rating entries only.
      #
      # @return [Array<Hash>]
      def ratings
        all_entries.select { |e| e['type'] == 'rating' }
      end

      # Filter to gap report entries only.
      #
      # @return [Array<Hash>]
      def gaps
        all_entries.select { |e| e['type'] == 'gap' }
      end

      # Average score across all ratings.
      #
      # @return [Float, nil] Average score, or nil if no ratings
      def average_score
        scores = ratings.map { |r| r['score'] }
        return nil if scores.empty?

        scores.sum.to_f / scores.size
      end

      private

      # Append a JSON entry as a new line.
      #
      # @param entry [Hash]
      # @return [void]
      def append(entry)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, 'a') do |f|
          f.puts(JSON.generate(entry))
        end
      end
    end
  end
end
```

**Step 4:** Run — pass
**Step 5:** Rubocop

---

### Task 9: GapDetector — heuristic gap detection

**Files:**
- Create: `lib/codebase_index/feedback/gap_detector.rb`
- Test: `spec/feedback/gap_detector_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/feedback/gap_detector_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/feedback/gap_detector'

RSpec.describe CodebaseIndex::Feedback::GapDetector do
  let(:feedback_store) { instance_double('CodebaseIndex::Feedback::Store') }

  subject(:detector) { described_class.new(feedback_store: feedback_store) }

  describe '#detect' do
    context 'with low-score queries' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([
          { 'query' => 'payment flow', 'score' => 1 },
          { 'query' => 'payment processing', 'score' => 2 },
          { 'query' => 'how auth works', 'score' => 5 }
        ])
        allow(feedback_store).to receive(:gaps).and_return([])
      end

      it 'identifies repeated low-score query patterns' do
        issues = detector.detect
        low_score = issues.find { |i| i[:type] == :repeated_low_scores }
        expect(low_score).not_to be_nil
        expect(low_score[:pattern]).to include('payment')
      end
    end

    context 'with gap reports' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([])
        allow(feedback_store).to receive(:gaps).and_return([
          { 'missing_unit' => 'PaymentService', 'unit_type' => 'service' },
          { 'missing_unit' => 'PaymentService', 'unit_type' => 'service' },
          { 'missing_unit' => 'RefundJob', 'unit_type' => 'job' }
        ])
      end

      it 'identifies frequently reported missing units' do
        issues = detector.detect
        freq = issues.find { |i| i[:type] == :frequently_missing }
        expect(freq).not_to be_nil
        expect(freq[:unit]).to eq('PaymentService')
        expect(freq[:count]).to eq(2)
      end
    end

    context 'with no feedback' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([])
        allow(feedback_store).to receive(:gaps).and_return([])
      end

      it 'returns empty array' do
        expect(detector.detect).to eq([])
      end
    end
  end
end
```

**Step 2:** Run — fail

**Step 3: Write implementation**

```ruby
# lib/codebase_index/feedback/gap_detector.rb
# frozen_string_literal: true

module CodebaseIndex
  module Feedback
    # Detects patterns in retrieval feedback that suggest coverage gaps.
    #
    # Analyzes ratings and gap reports to find:
    # - Repeated low-score queries with common keywords
    # - Frequently reported missing units
    #
    # @example
    #   detector = GapDetector.new(feedback_store: store)
    #   issues = detector.detect
    #   issues.each { |i| puts "#{i[:type]}: #{i[:description]}" }
    #
    class GapDetector
      LOW_SCORE_THRESHOLD = 2
      MIN_PATTERN_COUNT = 2
      MIN_GAP_COUNT = 2

      # @param feedback_store [Feedback::Store]
      def initialize(feedback_store:)
        @feedback_store = feedback_store
      end

      # Detect coverage gaps from accumulated feedback.
      #
      # @return [Array<Hash>] List of detected issues with :type, :description, and details
      def detect
        issues = []
        issues.concat(detect_low_score_patterns)
        issues.concat(detect_frequently_missing)
        issues
      end

      private

      # Find keyword patterns in low-scoring queries.
      #
      # @return [Array<Hash>]
      def detect_low_score_patterns
        low_ratings = @feedback_store.ratings.select { |r| r['score'] <= LOW_SCORE_THRESHOLD }
        return [] if low_ratings.size < MIN_PATTERN_COUNT

        # Extract keywords and find common ones
        keyword_counts = Hash.new(0)
        low_ratings.each do |rating|
          words = rating['query'].to_s.downcase.split(/\W+/).reject { |w| w.length < 3 }
          words.each { |w| keyword_counts[w] += 1 }
        end

        keyword_counts.select { |_, count| count >= MIN_PATTERN_COUNT }.map do |keyword, count|
          {
            type: :repeated_low_scores,
            pattern: keyword,
            count: count,
            description: "#{count} low-score queries mention '#{keyword}'"
          }
        end
      end

      # Find units that are frequently reported as missing.
      #
      # @return [Array<Hash>]
      def detect_frequently_missing
        unit_counts = Hash.new(0)
        @feedback_store.gaps.each do |gap|
          unit_counts[gap['missing_unit']] += 1
        end

        unit_counts.select { |_, count| count >= MIN_GAP_COUNT }.map do |unit, count|
          {
            type: :frequently_missing,
            unit: unit,
            count: count,
            description: "#{unit} reported missing #{count} times"
          }
        end
      end
    end
  end
end
```

**Step 4:** Run — pass
**Step 5:** Rubocop

---

### Task 10: StatusReporter — pipeline status snapshots

**Files:**
- Create: `lib/codebase_index/operator/status_reporter.rb`
- Test: `spec/operator/status_reporter_spec.rb`

**Step 1: Write the test, then implement**

The StatusReporter reads extraction output metadata and reports: last run timestamp, unit counts by type, staleness (time since last extraction), error count. Takes `output_dir` as constructor param, reads `manifest.json`.

```ruby
# spec/operator/status_reporter_spec.rb
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/operator/status_reporter'

RSpec.describe CodebaseIndex::Operator::StatusReporter do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(output_dir) }

  subject(:reporter) { described_class.new(output_dir: output_dir) }

  describe '#report' do
    context 'when manifest exists' do
      before do
        manifest = {
          'extracted_at' => '2026-02-15T10:00:00Z',
          'total_units' => 42,
          'counts' => { 'models' => 10, 'controllers' => 5, 'services' => 3 },
          'git_sha' => 'abc123',
          'git_branch' => 'main'
        }
        File.write(File.join(output_dir, 'manifest.json'), JSON.generate(manifest))
      end

      it 'returns status hash with extraction info' do
        status = reporter.report
        expect(status[:extracted_at]).to eq('2026-02-15T10:00:00Z')
        expect(status[:total_units]).to eq(42)
        expect(status[:git_sha]).to eq('abc123')
      end

      it 'includes unit counts by type' do
        status = reporter.report
        expect(status[:counts]).to eq({ 'models' => 10, 'controllers' => 5, 'services' => 3 })
      end

      it 'calculates staleness in seconds' do
        status = reporter.report
        expect(status[:staleness_seconds]).to be_a(Numeric)
        expect(status[:staleness_seconds]).to be > 0
      end

      it 'sets status to :ok when recent' do
        manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
        manifest['extracted_at'] = Time.now.iso8601
        File.write(File.join(output_dir, 'manifest.json'), JSON.generate(manifest))

        status = reporter.report
        expect(status[:status]).to eq(:ok)
      end
    end

    context 'when manifest does not exist' do
      it 'returns status :not_extracted' do
        status = reporter.report
        expect(status[:status]).to eq(:not_extracted)
        expect(status[:total_units]).to eq(0)
      end
    end
  end
end
```

```ruby
# lib/codebase_index/operator/status_reporter.rb
# frozen_string_literal: true

require 'json'
require 'time'

module CodebaseIndex
  module Operator
    # Reports pipeline status by reading extraction output metadata.
    #
    # @example
    #   reporter = StatusReporter.new(output_dir: 'tmp/codebase_index')
    #   status = reporter.report
    #   status[:status]           # => :ok
    #   status[:staleness_seconds] # => 3600
    #
    class StatusReporter
      STALE_THRESHOLD = 86_400 # 24 hours

      # @param output_dir [String] Path to extraction output directory
      def initialize(output_dir:)
        @output_dir = output_dir
      end

      # Generate a pipeline status report.
      #
      # @return [Hash] Status report with :status, :extracted_at, :total_units, :counts, :staleness_seconds
      def report
        manifest = read_manifest
        return not_extracted_report if manifest.nil?

        staleness = compute_staleness(manifest['extracted_at'])

        {
          status: staleness < STALE_THRESHOLD ? :ok : :stale,
          extracted_at: manifest['extracted_at'],
          total_units: manifest['total_units'] || 0,
          counts: manifest['counts'] || {},
          git_sha: manifest['git_sha'],
          git_branch: manifest['git_branch'],
          staleness_seconds: staleness
        }
      end

      private

      # @return [Hash, nil]
      def read_manifest
        path = File.join(@output_dir, 'manifest.json')
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      # @return [Hash]
      def not_extracted_report
        {
          status: :not_extracted,
          extracted_at: nil,
          total_units: 0,
          counts: {},
          git_sha: nil,
          git_branch: nil,
          staleness_seconds: nil
        }
      end

      # @param extracted_at [String, nil] ISO8601 timestamp
      # @return [Numeric]
      def compute_staleness(extracted_at)
        return Float::INFINITY if extracted_at.nil?

        Time.now - Time.parse(extracted_at)
      rescue ArgumentError
        Float::INFINITY
      end
    end
  end
end
```

---

### Task 11: ErrorEscalator — error classification

**Files:**
- Create: `lib/codebase_index/operator/error_escalator.rb`
- Test: `spec/operator/error_escalator_spec.rb`

Follow the same TDD pattern. ErrorEscalator classifies errors as `:transient` (network timeout, rate limit) or `:permanent` (NameError, missing file) and suggests remediation actions. Constructor takes no args. Method: `classify(error) -> { severity: :transient|:permanent, category: String, remediation: String }`.

```ruby
# lib/codebase_index/operator/error_escalator.rb
# frozen_string_literal: true

module CodebaseIndex
  module Operator
    # Classifies pipeline errors by severity and suggests remediation.
    #
    # @example
    #   escalator = ErrorEscalator.new
    #   result = escalator.classify(Timeout::Error.new("connection timed out"))
    #   result[:severity]     # => :transient
    #   result[:remediation]  # => "Retry after a short delay"
    #
    class ErrorEscalator
      TRANSIENT_PATTERNS = [
        { class_pattern: /Timeout|ETIMEDOUT/, category: 'timeout', remediation: 'Retry after a short delay' },
        { class_pattern: /Net::/, category: 'network', remediation: 'Check network connectivity and retry' },
        { class_pattern: /RateLimited|429/, category: 'rate_limit', remediation: 'Back off and retry with exponential delay' },
        { class_pattern: /CircuitOpenError/, category: 'circuit_open', remediation: 'Wait for circuit breaker reset timeout' },
        { class_pattern: /ConnectionPool|Busy/, category: 'resource_contention',
          remediation: 'Wait for resources to free up' }
      ].freeze

      PERMANENT_PATTERNS = [
        { class_pattern: /NameError|NoMethodError/, category: 'code_error',
          remediation: 'Fix the code error and re-extract' },
        { class_pattern: /Errno::ENOENT|FileNotFoundError/, category: 'missing_file',
          remediation: 'Verify file paths and re-run extraction' },
        { class_pattern: /JSON::ParserError/, category: 'corrupt_data', remediation: 'Clean index and re-extract' },
        { class_pattern: /ConfigurationError/, category: 'configuration',
          remediation: 'Review CodebaseIndex configuration' },
        { class_pattern: /ExtractionError/, category: 'extraction_failure',
          remediation: 'Check extraction logs for specific failure details' }
      ].freeze

      # Classify an error by severity and suggest remediation.
      #
      # @param error [StandardError] The error to classify
      # @return [Hash] :severity (:transient or :permanent), :category, :remediation, :error_class, :message
      def classify(error)
        error_string = "#{error.class} #{error.message}"

        match = find_match(error_string, TRANSIENT_PATTERNS, :transient) ||
                find_match(error_string, PERMANENT_PATTERNS, :permanent)

        if match
          match.merge(error_class: error.class.name, message: error.message)
        else
          {
            severity: :unknown,
            category: 'unclassified',
            remediation: 'Investigate error details and check logs',
            error_class: error.class.name,
            message: error.message
          }
        end
      end

      private

      # @param error_string [String]
      # @param patterns [Array<Hash>]
      # @param severity [Symbol]
      # @return [Hash, nil]
      def find_match(error_string, patterns, severity)
        patterns.each do |pattern|
          next unless error_string.match?(pattern[:class_pattern])

          return {
            severity: severity,
            category: pattern[:category],
            remediation: pattern[:remediation]
          }
        end
        nil
      end
    end
  end
end
```

Write matching spec with tests for transient errors (Timeout, Net::HTTP), permanent errors (NameError, ENOENT), and unknown errors.

---

### Task 12: PipelineGuard — rate limiting

**Files:**
- Create: `lib/codebase_index/operator/pipeline_guard.rb`
- Test: `spec/operator/pipeline_guard_spec.rb`

PipelineGuard enforces cooldown between pipeline runs. Constructor takes `cooldown: 300` (seconds). Method: `allow?(operation) -> Boolean` checks if enough time has passed since the last run of that operation. Method: `record!(operation)` records the current time. Uses a JSON file for state.

Follow the same TDD pattern as Tasks 7-11.

---

### Task 13: RetrievalTrace — extend Retriever

**Files:**
- Modify: `lib/codebase_index/retriever.rb`
- Modify: `spec/retriever_spec.rb`

Add `RetrievalTrace` struct to Retriever: `classification`, `strategy`, `candidate_count`, `ranked_count`, `tokens_used`, `elapsed_ms`. Add a `trace` field to `RetrievalResult`. Populate it during `#retrieve`.

```ruby
# Add to lib/codebase_index/retriever.rb, inside the class:

# Diagnostic trace for retrieval quality analysis.
RetrievalTrace = Struct.new(:classification, :strategy, :candidate_count,
                            :ranked_count, :tokens_used, :elapsed_ms,
                            keyword_init: true)
```

Update `RetrievalResult` to include `:trace`. Update `#retrieve` to capture timing and trace data. Add specs verifying `result.trace` is populated.

---

### Task 14: MCP operator and feedback tools

**Files:**
- Modify: `lib/codebase_index/mcp/server.rb`
- Modify: `spec/mcp/server_spec.rb`

Add 9 new tools to the MCP server following the existing pattern. Each tool is a `define_tool` call in a new private method. Group them:

- `define_operator_tools(server, respond)` — 5 tools: `pipeline_extract`, `pipeline_embed`, `pipeline_status`, `pipeline_diagnose`, `pipeline_repair`
- `define_feedback_tools(server, respond)` — 4 tools: `retrieval_rate`, `retrieval_report_gap`, `retrieval_explain`, `retrieval_suggest`

The `build` method accepts optional `operator:` and `feedback_store:` params. Tools gracefully degrade when these are nil (return "not configured" message).

Update server_spec: tool count from 11 to 20, add tool name expectations, add basic call specs for 2-3 representative tools.

**After completing all agentic tasks:** Full suite + rubocop verification.

---

## Agent: console-core (Tasks 15-22)

**Backlog items:** B-058
**Owns:** `lib/codebase_index/console/`, `spec/console/`, `exe/codebase-console-mcp`

### Task 15: ModelValidator — validates model/column names

**Files:**
- Create: `lib/codebase_index/console/model_validator.rb`
- Test: `spec/console/model_validator_spec.rb`

```ruby
# lib/codebase_index/console/model_validator.rb
# frozen_string_literal: true

module CodebaseIndex
  module Console
    class ValidationError < CodebaseIndex::Error; end

    # Validates model names and column names against the Rails schema.
    #
    # In production, validates against AR::Base.descendants and model.column_names.
    # Accepts an injectable registry for testing without Rails.
    #
    # @example
    #   validator = ModelValidator.new(registry: { 'User' => %w[id email name] })
    #   validator.validate_model!('User')      # => true
    #   validator.validate_model!('Hacker')    # => raises ValidationError
    #   validator.validate_column!('User', 'email')  # => true
    #
    class ModelValidator
      # @param registry [Hash<String, Array<String>>] Model name => column names mapping
      def initialize(registry:)
        @registry = registry
      end

      # Validate that a model name is known.
      #
      # @param model_name [String]
      # @return [true]
      # @raise [ValidationError] if model is unknown
      def validate_model!(model_name)
        return true if @registry.key?(model_name)

        raise ValidationError, "Unknown model: #{model_name}. Available: #{@registry.keys.sort.join(', ')}"
      end

      # Validate that a column exists on a model.
      #
      # @param model_name [String]
      # @param column_name [String]
      # @return [true]
      # @raise [ValidationError] if column is unknown
      def validate_column!(model_name, column_name)
        validate_model!(model_name)
        columns = @registry[model_name]
        return true if columns.include?(column_name)

        raise ValidationError, "Unknown column '#{column_name}' on #{model_name}. Available: #{columns.sort.join(', ')}"
      end

      # Validate multiple columns at once.
      #
      # @param model_name [String]
      # @param column_names [Array<String>]
      # @return [true]
      # @raise [ValidationError] if any column is unknown
      def validate_columns!(model_name, column_names)
        column_names.each { |col| validate_column!(model_name, col) }
        true
      end

      # List all known model names.
      #
      # @return [Array<String>]
      def model_names
        @registry.keys.sort
      end

      # List columns for a model.
      #
      # @param model_name [String]
      # @return [Array<String>]
      def columns_for(model_name)
        validate_model!(model_name)
        @registry[model_name].sort
      end
    end
  end
end
```

Write matching spec testing valid/invalid model names, valid/invalid columns, multi-column validation, model_names list, columns_for.

---

### Task 16: SafeContext — transaction rollback + timeout

**Files:**
- Create: `lib/codebase_index/console/safe_context.rb`
- Test: `spec/console/safe_context_spec.rb`

SafeContext wraps tool execution in a rolled-back transaction with statement timeout. Constructor takes `connection:` (mock in tests), `timeout_ms: 5000`, `redacted_columns: []`. Method: `execute { |conn| ... }` — runs block inside a transaction, rolls back after, enforces timeout. Method: `redact(hash, model_name)` — replaces redacted column values with `"[REDACTED]"`.

---

### Task 17: Bridge — JSON-lines protocol handler

**Files:**
- Create: `lib/codebase_index/console/bridge.rb`
- Test: `spec/console/bridge_spec.rb`

Bridge accepts JSON-lines requests on `$stdin`, validates against ModelValidator, dispatches to tool handlers, writes JSON-lines responses to `$stdout`. Constructor takes `input:`, `output:`, `model_validator:`, `safe_context:`. Method: `run` — read loop. Method: `handle_request(request_hash) -> response_hash`.

Protocol:
- Request: `{"id":"req_1","tool":"count","params":{"model":"Order","scope":{"status":"pending"}}}`
- Response: `{"id":"req_1","ok":true,"result":{"count":1847},"timing_ms":12.3}`
- Error: `{"id":"req_1","ok":false,"error":"Model not found: Ordr","error_type":"validation"}`

---

### Task 18: ConnectionManager — Docker/direct/SSH

**Files:**
- Create: `lib/codebase_index/console/connection_manager.rb`
- Test: `spec/console/connection_manager_spec.rb`

ConnectionManager spawns and manages the bridge process. Constructor takes `config:` hash with `mode:` (docker/direct/ssh), `command:`, and mode-specific fields. Methods: `connect!`, `disconnect!`, `send_request(request) -> response`, `alive?`. Implements heartbeat (30s) and reconnect with exponential backoff (max 5 retries).

---

### Task 19: Tier 1 tools — 9 read-only tools

**Files:**
- Create: `lib/codebase_index/console/tools/tier1.rb`
- Test: `spec/console/tools/tier1_spec.rb`

All 9 tools follow the same pattern — they build a bridge request hash from validated input params. Each tool is a method that returns a request hash.

```ruby
# lib/codebase_index/console/tools/tier1.rb
# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Tools
      # Tier 1: MVP read-only tools for querying live Rails data.
      #
      # Each method builds a bridge request hash from validated parameters.
      # The bridge executes the query against the Rails database.
      #
      module Tier1
        module_function

        # Count records matching scope conditions.
        #
        # @param model [String] Model name
        # @param scope [Hash, nil] Filter conditions
        # @return [Hash] Bridge request
        def console_count(model:, scope: nil)
          { tool: 'count', params: { model: model, scope: scope }.compact }
        end

        # Random sample of records.
        #
        # @param model [String] Model name
        # @param scope [Hash, nil] Filter conditions
        # @param limit [Integer] Max records (default: 5, max: 25)
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        def console_sample(model:, scope: nil, limit: 5, columns: nil)
          limit = [limit, 25].min
          { tool: 'sample', params: { model: model, scope: scope, limit: limit, columns: columns }.compact }
        end

        # Find a single record by primary key or unique column.
        #
        # @param model [String] Model name
        # @param id [Integer, nil] Primary key value
        # @param by [Hash, nil] Unique column lookup (e.g., { email: "x@y.com" })
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        def console_find(model:, id: nil, by: nil, columns: nil)
          { tool: 'find', params: { model: model, id: id, by: by, columns: columns }.compact }
        end

        # Extract column values.
        #
        # @param model [String] Model name
        # @param columns [Array<String>] Column names to pluck
        # @param scope [Hash, nil] Filter conditions
        # @param limit [Integer] Max records (default: 100, max: 1000)
        # @param distinct [Boolean] Return unique values only
        # @return [Hash] Bridge request
        def console_pluck(model:, columns:, scope: nil, limit: 100, distinct: false)
          limit = [limit, 1000].min
          { tool: 'pluck', params: { model: model, columns: columns, scope: scope,
                                     limit: limit, distinct: distinct }.compact }
        end

        # Run aggregate function on a column.
        #
        # @param model [String] Model name
        # @param function [String] One of: sum, avg, minimum, maximum
        # @param column [String] Column to aggregate
        # @param scope [Hash, nil] Filter conditions
        # @return [Hash] Bridge request
        def console_aggregate(model:, function:, column:, scope: nil)
          { tool: 'aggregate', params: { model: model, function: function, column: column, scope: scope }.compact }
        end

        # Count associated records.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param association [String] Association name
        # @param scope [Hash, nil] Filter on the association
        # @return [Hash] Bridge request
        def console_association_count(model:, id:, association:, scope: nil)
          { tool: 'association_count',
            params: { model: model, id: id, association: association, scope: scope }.compact }
        end

        # Get database schema for a model.
        #
        # @param model [String] Model name
        # @param include_indexes [Boolean] Include index information
        # @return [Hash] Bridge request
        def console_schema(model:, include_indexes: false)
          { tool: 'schema', params: { model: model, include_indexes: include_indexes } }
        end

        # Recently created/updated records.
        #
        # @param model [String] Model name
        # @param order_by [String] Column to sort by (default: created_at)
        # @param direction [String] Sort direction (default: desc)
        # @param limit [Integer] Max records (default: 10, max: 50)
        # @param scope [Hash, nil] Filter conditions
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        def console_recent(model:, order_by: 'created_at', direction: 'desc', limit: 10, scope: nil, columns: nil)
          limit = [limit, 50].min
          { tool: 'recent', params: { model: model, order_by: order_by, direction: direction,
                                      limit: limit, scope: scope, columns: columns }.compact }
        end

        # System health check.
        #
        # @return [Hash] Bridge request
        def console_status
          { tool: 'status', params: {} }
        end
      end
    end
  end
end
```

Test each tool method returns the correct request hash with expected fields, limit capping, and compact params.

---

### Task 20: Console MCP Server

**Files:**
- Create: `lib/codebase_index/console/server.rb`
- Test: `spec/console/server_spec.rb`

Console MCP server wires the bridge, validator, safe context, and Tier 1 tools into an MCP::Server. Similar structure to the index MCP server but for live data.

Method: `build(config:) -> MCP::Server` — creates connection manager, model validator (populated from bridge `status` response), and registers all Tier 1 tools.

---

### Task 21: Console executable

**Files:**
- Create: `exe/codebase-console-mcp`

Standalone executable script. Reads config from `CODEBASE_CONSOLE_CONFIG` env var or `~/.codebase_index/console.yml`. Boots the Console MCP server with StdioTransport.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'codebase_index/console/server'

config_path = ENV.fetch('CODEBASE_CONSOLE_CONFIG', File.expand_path('~/.codebase_index/console.yml'))
config = File.exist?(config_path) ? YAML.safe_load_file(config_path) : {}

server = CodebaseIndex::Console::Server.build(config: config)
transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
```

---

### Task 22: Full console-core verification

Run full suite, rubocop on all new files. Expected: ~40-60 new specs pass, full suite green.

---

## Agent: eval (Tasks 23-27)

**Backlog items:** B-059
**Owns:** `lib/codebase_index/evaluation/`, `spec/evaluation/`, `lib/tasks/codebase_index_evaluation.rake`

### Task 23: QuerySet — evaluation query management

**Files:**
- Create: `lib/codebase_index/evaluation/query_set.rb`
- Test: `spec/evaluation/query_set_spec.rb`

QuerySet loads/saves evaluation queries from JSON. Each query has: `query` (string), `expected_units` (array of identifiers), `intent` (lookup/trace/explain/compare), `scope` (specific/bounded/broad), `tags` (array).

### Task 24: Metrics — scoring functions

**Files:**
- Create: `lib/codebase_index/evaluation/metrics.rb`
- Test: `spec/evaluation/metrics_spec.rb`

Pure math module. Methods: `precision_at_k(retrieved, relevant, k:)`, `recall(retrieved, relevant)`, `mrr(retrieved, relevant)`, `context_completeness(retrieved, required)`, `token_efficiency(relevant_tokens, total_tokens)`.

```ruby
# lib/codebase_index/evaluation/metrics.rb
# frozen_string_literal: true

module CodebaseIndex
  module Evaluation
    # Retrieval quality metrics.
    #
    # All methods are stateless pure functions that take arrays of identifiers
    # and return numeric scores.
    #
    module Metrics
      module_function

      # Fraction of top-k results that are relevant.
      #
      # @param retrieved [Array<String>] Retrieved unit identifiers (ordered)
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @param k [Integer] Cutoff
      # @return [Float] 0.0 to 1.0
      def precision_at_k(retrieved, relevant, k: 5)
        return 0.0 if retrieved.empty? || relevant.empty?

        top_k = retrieved.first(k)
        relevant_set = relevant.to_set
        hits = top_k.count { |id| relevant_set.include?(id) }
        hits.to_f / k
      end

      # Fraction of relevant items that were retrieved.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @return [Float] 0.0 to 1.0
      def recall(retrieved, relevant)
        return 0.0 if relevant.empty?

        retrieved_set = retrieved.to_set
        found = relevant.count { |id| retrieved_set.include?(id) }
        found.to_f / relevant.size
      end

      # Mean Reciprocal Rank — inverse of the rank of the first relevant result.
      #
      # @param retrieved [Array<String>] Retrieved identifiers (ordered)
      # @param relevant [Array<String>] Ground-truth relevant identifiers
      # @return [Float] 0.0 to 1.0
      def mrr(retrieved, relevant)
        relevant_set = relevant.to_set
        retrieved.each_with_index do |id, idx|
          return 1.0 / (idx + 1) if relevant_set.include?(id)
        end
        0.0
      end

      # Fraction of required units present in retrieved results.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param required [Array<String>] Required identifiers (subset of relevant)
      # @return [Float] 0.0 to 1.0
      def context_completeness(retrieved, required)
        return 1.0 if required.empty?

        retrieved_set = retrieved.to_set
        found = required.count { |id| retrieved_set.include?(id) }
        found.to_f / required.size
      end

      # Ratio of relevant tokens to total tokens in context.
      #
      # @param relevant_tokens [Integer] Tokens from relevant units
      # @param total_tokens [Integer] Total tokens in assembled context
      # @return [Float] 0.0 to 1.0
      def token_efficiency(relevant_tokens, total_tokens)
        return 0.0 if total_tokens.zero?

        [relevant_tokens.to_f / total_tokens, 1.0].min
      end
    end
  end
end
```

Test each metric with known inputs and expected outputs.

---

### Task 25: Evaluator — runs queries and scores

**Files:**
- Create: `lib/codebase_index/evaluation/evaluator.rb`
- Test: `spec/evaluation/evaluator_spec.rb`

Evaluator takes a `retriever:` and `query_set:`. Method: `evaluate -> EvaluationReport` runs each query, collects results, computes metrics. `EvaluationReport` struct: `results` (per-query), `aggregates` (overall metrics).

---

### Task 26: BaselineRunner — comparison baselines

**Files:**
- Create: `lib/codebase_index/evaluation/baseline_runner.rb`
- Test: `spec/evaluation/baseline_runner_spec.rb`

BaselineRunner runs simple baselines for comparison: `:grep` (string match on identifiers), `:random` (random selection), `:file_level` (return whole files). Takes `metadata_store:` for unit access. Method: `run(query, strategy:, limit:) -> Array<String>` (identifiers).

---

### Task 27: ReportGenerator + rake task

**Files:**
- Create: `lib/codebase_index/evaluation/report_generator.rb`
- Create: `lib/tasks/codebase_index_evaluation.rake`
- Test: `spec/evaluation/report_generator_spec.rb`

ReportGenerator takes an `EvaluationReport` and outputs JSON. Rake task `codebase_index:evaluate` wires everything together.

**After completing all eval tasks:** Full suite + rubocop.

---

## Wave 2

Wave 2 starts after Wave 1 is committed to main. Both agents extend `console/server.rb` using the registration protocol.

---

## Agent: console-domain (Tasks 28-31)

**Backlog items:** B-060
**Owns:** `console/tools/tier2.rb`, `console/tools/tier3.rb`, `console/adapters/`, specs

### Task 28: Tier 2 domain tools

9 tools following the Tier 1 pattern. Each is a method that returns a bridge request hash. `console_diagnose_model` composes multiple Tier 1 calls (count, recent, aggregate). `console_update_setting` includes a `requires_confirmation: true` flag.

### Task 29: Job backend adapters

**Files:**
- Create: `lib/codebase_index/console/adapters/sidekiq_adapter.rb`
- Create: `lib/codebase_index/console/adapters/solid_queue_adapter.rb`
- Create: `lib/codebase_index/console/adapters/good_job_adapter.rb`
- Tests for each

Each adapter implements: `queue_stats`, `recent_failures(limit:)`, `find_job(id)`, `scheduled_jobs(limit:)`. The bridge detects which backend is available and delegates.

### Task 30: Tier 3 analytics tools + cache adapter

10 tools. Job tools delegate to the appropriate backend adapter. Cache tools delegate to a cache adapter that auto-detects Redis/Solid Cache/memory/file.

### Task 31: Register Tier 2-3 in server

Modify `console/server.rb`: add `register_tier2_tools` and `register_tier3_tools` methods. Call them from `build`. Update `safe_context.rb` with Layer 5 confirmation protocol for `console_update_setting`.

---

## Agent: console-advanced (Tasks 32-36)

**Backlog items:** B-061
**Owns:** `console/tools/tier4.rb`, `console/sql_validator.rb`, `console/audit_logger.rb`, `console/confirmation.rb`, specs

### Task 32: SqlValidator — SQL safety

**Files:**
- Create: `lib/codebase_index/console/sql_validator.rb`
- Test: `spec/console/sql_validator_spec.rb`

Validates SQL strings: allows SELECT and WITH...SELECT, rejects INSERT/UPDATE/DELETE/DROP/ALTER/TRUNCATE/CREATE. Pattern-based validation (not full parsing).

### Task 33: AuditLogger — Tier 4 logging

**Files:**
- Create: `lib/codebase_index/console/audit_logger.rb`
- Test: `spec/console/audit_logger_spec.rb`

Logs all Tier 4 invocations to a JSONL file: tool name, params, timestamp, confirmation status, result summary.

### Task 34: Confirmation — human-in-the-loop

**Files:**
- Create: `lib/codebase_index/console/confirmation.rb`
- Test: `spec/console/confirmation_spec.rb`

Sends a confirmation request via MCP notification and waits for approval. If denied, raises `ConfirmationDeniedError`.

### Task 35: Tier 4 tools

3 guarded tools: `console_eval` (requires confirmation), `console_sql` (SqlValidator), `console_query` (programmatic query builder).

### Task 36: Register Tier 4 in server

Modify `console/server.rb`: add `register_tier4_tools`. Add `--audit-log` flag to executable.

---

## Post-Implementation (Tasks 37-38)

### Task 37: Update backlog and docs

Add B-053 through B-061 to `docs/backlog.json` (all resolved). Update `docs/README.md` status table: all 5 remaining layers to complete.

### Task 38: Update session state

Update `.claude/context/session-state.md` with final breadcrumbs.

---

## Verification Checklist

After both waves:
1. `bundle exec rspec --format progress --format json --out tmp/test_results.json` — all ~1,380 examples pass
2. `bundle exec rubocop` — no new offenses in created files
3. All backlog items resolved
4. README status table fully updated
5. Session state current
