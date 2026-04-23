# frozen_string_literal: true

require 'spec_helper'
require 'woods/chunking/semantic_chunker'
require 'woods/extracted_unit'

RSpec.describe Woods::Chunking::SemanticChunker do
  subject(:chunker) { described_class.new }

  let(:small_unit) do
    unit = Woods::ExtractedUnit.new(
      type: :model,
      identifier: 'Tag',
      file_path: 'app/models/tag.rb'
    )
    unit.source_code = "class Tag < ApplicationRecord\nend"
    unit.metadata = {}
    unit
  end

  let(:large_model_unit) do
    unit = Woods::ExtractedUnit.new(
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
    unit = Woods::ExtractedUnit.new(
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
        unit = Woods::ExtractedUnit.new(
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
        unit = Woods::ExtractedUnit.new(
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
      expect(chunks).to all(be_a(Woods::Chunking::Chunk))
    end
  end

  describe '#chunk with class-like units (MethodChunker)' do
    subject(:chunker) { described_class.new(threshold: 10) }

    let(:service_source) do
      <<~RUBY
        class PaymentProcessor
          include Retryable

          REQUIRED_ATTRS = %i[amount currency].freeze

          attr_reader :order

          def initialize(order)
            @order = order
          end

          def call
            charge_card
            record_payment
          end

          def refund
            stripe.refund(charge_id)
          end

          private

          def charge_card
            stripe.charge(order.amount)
          end

          def record_payment
            Payment.create!(order: order)
          end
        end
      RUBY
    end

    let(:service_unit) do
      unit = Woods::ExtractedUnit.new(
        type: :service,
        identifier: 'PaymentProcessor',
        file_path: 'app/services/payment_processor.rb'
      )
      unit.source_code = service_source
      unit.metadata = {}
      unit
    end

    it 'produces a summary chunk with class declaration and DSL calls' do
      types = chunker.chunk(service_unit).map(&:chunk_type)
      expect(types.first).to eq(:summary)
    end

    it 'produces one chunk per public method' do
      types = chunker.chunk(service_unit).map(&:chunk_type)
      expect(types).to include(:method_initialize, :method_call, :method_refund)
    end

    it 'bundles private methods into a single chunk' do
      chunks = chunker.chunk(service_unit)
      private_chunk = chunks.find { |c| c.chunk_type == :private_methods }

      expect(private_chunk).not_to be_nil
      expect(private_chunk.content).to include('def charge_card')
      expect(private_chunk.content).to include('def record_payment')
    end

    it 'applies to jobs, mailers, concerns, policies, and other class-like types' do
      %i[job mailer concern policy pundit_policy serializer decorator
         interactor component graphql_resolver helper validator api_client].each do |type|
        unit = Woods::ExtractedUnit.new(type: type, identifier: 'Thing', file_path: 'x.rb')
        unit.source_code = service_source
        unit.metadata = {}
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_call), "expected MethodChunker to handle #{type}"
      end
    end

    it 'leaves unhandled types as :whole' do
      unit = Woods::ExtractedUnit.new(type: :migration, identifier: 'AddFoo', file_path: 'm.rb')
      unit.source_code = service_source
      unit.metadata = {}
      types = chunker.chunk(unit).map(&:chunk_type)
      expect(types).to eq([:whole])
    end
  end

  describe '#chunk with a max_chars safety net' do
    # 1kB ceiling — well under anything real but easy to exceed in a test.
    subject(:chunker) { described_class.new(threshold: 10, max_chars: 1024) }

    let(:huge_service_unit) do
      body = (['    something_long_enough_to_matter(arg1, arg2, arg3)'] * 200).join("\n")
      unit = Woods::ExtractedUnit.new(
        type: :service,
        identifier: 'HugeService',
        file_path: 'app/services/huge_service.rb'
      )
      unit.source_code = "class HugeService\n  def call\n#{body}\n  end\nend"
      unit.metadata = {}
      unit
    end

    it 'slices any chunk whose content exceeds max_chars into parts' do
      chunks = chunker.chunk(huge_service_unit)
      expect(chunks.map(&:content)).to all(satisfy { |c| c.length <= 1024 })
    end

    it 'preserves provenance in the sliced chunk_type suffix' do
      chunks = chunker.chunk(huge_service_unit)
      # The oversize method chunk should emit :method_call_part_0, _part_1, …
      sliced_types = chunks.map(&:chunk_type).select { |t| t.to_s.start_with?('method_call_part_') }
      expect(sliced_types.size).to be >= 2
    end

    it 'leaves already-small chunks alone' do
      small_service = Woods::ExtractedUnit.new(
        type: :service, identifier: 'Small', file_path: 's.rb'
      )
      small_service.source_code = "class Small\n  def call\n    :ok\n  end\nend"
      small_service.metadata = {}
      chunks = chunker.chunk(small_service)
      expect(chunks.map(&:chunk_type)).not_to include(a_string_matching(/_part_/))
    end

    it 'handles a single line longer than max_chars by hard-splitting it' do
      long_line = 'x' * 3000
      unit = Woods::ExtractedUnit.new(type: :service, identifier: 'Long', file_path: 'l.rb')
      unit.source_code = "class Long\n  def call\n#{long_line}\n  end\nend"
      unit.metadata = {}
      chunks = chunker.chunk(unit)
      expect(chunks.map(&:content)).to all(satisfy { |c| c.length <= 1024 })
    end
  end

  describe '#enforce_chunk_limits!' do
    subject(:chunker) { described_class.new(max_chars: 1024) }

    let(:unit) do
      unit = Woods::ExtractedUnit.new(
        type: :rails_source, identifier: 'Rails::Big', file_path: '/gems/rails/big.rb'
      )
      unit.source_code = 'class Big; end'
      unit.metadata = {}
      unit
    end

    it 'splits oversize pre-existing chunks into line-balanced siblings' do
      body = (['    long_line_to_ensure_slicing(arg1, arg2)'] * 50).join("\n")
      unit.chunks = [{ content: body, chunk_type: :section }]

      chunker.enforce_chunk_limits!(unit)

      expect(unit.chunks.size).to be > 1
      expect(unit.chunks.map { |c| c[:content].length }).to all(be <= 1024)
      expect(unit.chunks.map { |c| c[:chunk_type] }).to all(match(/section_part_\d+/))
    end

    it 'leaves small pre-existing chunks untouched' do
      unit.chunks = [{ content: 'short content', chunk_type: :summary }]

      chunker.enforce_chunk_limits!(unit)

      expect(unit.chunks).to eq([{ content: 'short content', chunk_type: :summary }])
    end

    it 'accepts string-keyed chunk hashes (ExtractedUnit JSON roundtrip shape)' do
      body = ('x' * 2000)
      unit.chunks = [{ 'content' => body, 'chunk_type' => 'blob' }]

      chunker.enforce_chunk_limits!(unit)

      expect(unit.chunks.size).to be > 1
      expect(unit.chunks.map { |c| c[:chunk_type] }).to all(match(/blob_part_\d+/))
    end

    it 'is a no-op when max_chars is unset' do
      unbounded = described_class.new
      body = ('x' * 5000)
      unit.chunks = [{ content: body, chunk_type: :blob }]

      unbounded.enforce_chunk_limits!(unit)

      expect(unit.chunks.size).to eq(1)
    end

    it 'is a no-op on empty chunks array' do
      unit.chunks = []
      expect { chunker.enforce_chunk_limits!(unit) }.not_to(change { unit.chunks })
    end
  end

  describe '#enforce_chunk_limits! with a token-authoritative counter' do
    let(:fake_counter) do
      Class.new do
        attr_reader :calls

        def initialize(lengths_over:)
          @lengths_over = lengths_over
          @calls = 0
        end

        def count(text)
          @calls += 1
          @lengths_over.any? { |limit| text.length > limit } ? 9_000 : 100
        end
      end
    end

    let(:unit) do
      Woods::ExtractedUnit.new(
        type: :rails_source, identifier: 'Giant::Class', file_path: 'x.rb'
      )
    end

    it 'uses the real tokenizer to detect oversize slices and re-splits them' do
      # Oversize while > 1000 chars; fits below.
      counter = fake_counter.new(lengths_over: [1000])
      chunker = described_class.new(
        max_chars: 2000, token_counter: counter, max_tokens: 8192
      )
      unit.chunks = [{ content: ("line of code\n" * 200), chunk_type: :whole }]

      chunker.enforce_chunk_limits!(unit)

      expect(unit.chunks.size).to be > 1
      expect(unit.chunks.map { |c| c[:content].length }).to all(be <= 1000)
    end

    it 'stops recursive splitting at the MIN_SLICE_CHARS floor' do
      counter = fake_counter.new(lengths_over: [0])
      chunker = described_class.new(
        max_chars: 2000, token_counter: counter, max_tokens: 8192
      )
      unit.chunks = [{ content: ('x' * 3000), chunk_type: :whole }]

      chunker.enforce_chunk_limits!(unit)

      expect(unit.chunks).not_to be_empty
      expect(unit.chunks.size).to be < 50
    end

    it 'activates enforcement even when max_chars is nil' do
      counter = fake_counter.new(lengths_over: [1000])
      chunker = described_class.new(
        max_chars: nil, token_counter: counter, max_tokens: 8192
      )
      unit.chunks = [{ content: ("row\n" * 500), chunk_type: :whole }]

      expect { chunker.enforce_chunk_limits!(unit) }
        .to(change { unit.chunks.size })
    end
  end
end
