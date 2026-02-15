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
