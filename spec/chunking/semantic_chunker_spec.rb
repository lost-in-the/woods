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

      it 'keeps two class methods in distinct chunks instead of clobbering under "self"' do
        small_threshold_chunker = described_class.new(threshold: 10)
        unit = Woods::ExtractedUnit.new(
          type: :controller,
          identifier: 'ReportsController',
          file_path: 'app/controllers/reports_controller.rb'
        )
        unit.source_code = <<~RUBY
          class ReportsController < ApplicationController
            def self.default_format
              :csv
            end

            def self.exportable?
              true
            end

            def index
              @reports = Report.all
            end
          end
        RUBY

        chunk_types = small_threshold_chunker.chunk(unit).map(&:chunk_type)
        expect(chunk_types).to include(:'action_self.default_format')
        expect(chunk_types).to include(:'action_self.exportable')
        expect(chunk_types).not_to include(:action_self)
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

  describe 'nested block and endless-def depth tracking (B-083 / #195)' do
    subject(:chunker) { described_class.new(threshold: 10) }

    def build_unit(type, identifier, source)
      unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: 'x.rb')
      unit.source_code = source
      unit.metadata = {}
      unit
    end

    context 'with a controller action containing a nested multi-line if' do
      let(:unit) do
        build_unit(:controller, 'PostsController', <<~RUBY)
          class PostsController < ApplicationController
            def create
              @post = Post.new(post_params)
              if @post.save
                redirect_to @post
              end
              NotifyJob.perform_later(@post)
            end

            def destroy
              @post.destroy
              redirect_to posts_url
            end
          end
        RUBY
      end

      it 'keeps statements after the nested if inside the action chunk' do
        create_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_create }
        expect(create_chunk.content).to include('NotifyJob.perform_later(@post)')
      end

      it 'keeps the action closing end inside the action chunk' do
        create_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_create }
        expect(create_chunk.content.scan(/^\s*end\s*$/).size).to eq(2)
      end

      it 'does not leak action lines into the summary chunk' do
        summary = chunker.chunk(unit).find { |c| c.chunk_type == :summary }
        expect(summary.content).not_to include('NotifyJob')
      end

      it 'still recognizes the following action' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:action_destroy)
      end
    end

    context 'with a controller action containing a nested case/when' do
      let(:unit) do
        build_unit(:controller, 'PostsController', <<~RUBY)
          class PostsController < ApplicationController
            def show
              case params[:variant]
              when 'json'
                render json: @post
              else
                render :show
              end
              track_view
            end

            def index
              @posts = Post.all
            end
          end
        RUBY
      end

      it 'keeps statements after the case inside the action chunk' do
        show_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_show }
        expect(show_chunk.content).to include('track_view')
      end

      it 'does not swallow the following action' do
        index_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_index }
        expect(index_chunk.content).to include('@posts = Post.all')
      end
    end

    context 'with an endless controller action followed by normal actions' do
      let(:unit) do
        build_unit(:controller, 'HealthController', <<~RUBY)
          class HealthController < ApplicationController
            def show = head :ok

            def index
              render json: STATUS
            end

            def create
              Probe.run!
              head :created
            end
          end
        RUBY
      end

      it 'emits three separate action chunks' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:action_show, :action_index, :action_create)
      end

      it 'gives the endless action its own single-line chunk' do
        show_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_show }
        expect(show_chunk.content.strip).to eq('def show = head :ok')
      end

      it 'does not swallow subsequent actions into the endless one' do
        index_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :action_index }
        expect(index_chunk.content).to include('render json: STATUS')
        expect(index_chunk.content).not_to include('Probe')
      end
    end

    context 'with a service method containing a nested multi-line if' do
      let(:unit) do
        build_unit(:service, 'Syncer', <<~RUBY)
          class Syncer
            def call
              if stale?
                refresh
              end
              publish!
            end

            def status
              :ok
            end
          end
        RUBY
      end

      it 'keeps statements after the nested if inside the method chunk' do
        call_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_call }
        expect(call_chunk.content).to include('publish!')
        expect(call_chunk.content.scan(/^\s*end\s*$/).size).to eq(2)
      end

      it 'does not leak method lines into the summary chunk' do
        summary = chunker.chunk(unit).find { |c| c.chunk_type == :summary }
        expect(summary.content).not_to include('publish!')
      end

      it 'still recognizes the following method' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_status)
      end
    end

    context 'with an endless service method followed by two normal methods' do
      let(:unit) do
        build_unit(:service, 'Toolkit', <<~RUBY)
          class Toolkit
            def ping = :pong

            def alpha
              build(1)
            end

            def beta
              build(2)
            end
          end
        RUBY
      end

      it 'emits three separate method chunks' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_ping, :method_alpha, :method_beta)
      end

      it 'gives the endless method its own single-line chunk' do
        ping_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_ping }
        expect(ping_chunk.content.strip).to eq('def ping = :pong')
      end

      it 'does not swallow subsequent methods into the endless one' do
        alpha_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_alpha }
        expect(alpha_chunk.content).to include('build(1)')
        expect(alpha_chunk.content).not_to include('build(2)')
      end
    end

    context 'with an operator method definition (def ==) that has a body' do
      let(:unit) do
        build_unit(:service, 'Money', <<~RUBY)
          class Money
            def ==(other)
              amount == other.amount
            end

            def positive?
              amount.positive?
            end
          end
        RUBY
      end

      it 'tracks it as a normal method, keeping its body and end in one chunk' do
        eq_chunk = chunker.chunk(unit).find { |c| c.content.include?('def ==(other)') }
        expect(eq_chunk.chunk_type).to eq(:'method_==')
        expect(eq_chunk.content).to include('amount == other.amount')
        expect(eq_chunk.content).to include('end')
      end

      it 'does not leak the operator method body into the summary chunk' do
        summary = chunker.chunk(unit).find { |c| c.chunk_type == :summary }
        expect(summary.content).not_to include('other.amount')
      end

      it 'still recognizes the following method' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_positive)
      end
    end

    context 'with a setter method definition (def x=) that has a body' do
      let(:unit) do
        build_unit(:service, 'Config', <<~RUBY)
          class Config
            def timeout=(value)
              @timeout = Integer(value)
            end

            def retries
              @retries || 3
            end
          end
        RUBY
      end

      it 'is not misread as endless — body and end stay in the method chunk' do
        setter_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_timeout }
        expect(setter_chunk.content).to include('@timeout = Integer(value)')
      end

      it 'still recognizes the following method' do
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_retries)
      end
    end

    context 'with trailing modifiers, chained ends, and assignment-position keywords' do
      let(:unit) do
        build_unit(:service, 'Reporter', <<~RUBY)
          class Reporter
            def names
              return if skipped?
              list = items.map do |item|
                item.name
              end.compact
              label = if urgent?
                'URGENT'
              else
                'normal'
              end
              [label, list].join(': ')
            end

            def follow_up
              :done
            end
          end
        RUBY
      end

      it 'balances the depth so the method closes at its real end' do
        names_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_names }
        expect(names_chunk.content).to include("[label, list].join(': ')")
      end

      it 'does not swallow the following method' do
        follow_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_follow_up }
        expect(follow_chunk.content).to include(':done')
      end
    end

    context 'with a model method containing a guard-style nested if' do
      let(:unit) do
        build_unit(:model, 'Post', <<~RUBY)
          class Post < ApplicationRecord
            has_many :comments

            def publish!
              if draft?
                update!(published_at: Time.current)
              end
              notify_subscribers
            end

            def archived?
              archived_at.present?
            end
          end
        RUBY
      end

      it 'keeps the whole method body in the :methods chunk' do
        methods_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :methods }
        expect(methods_chunk.content).to include('notify_subscribers')
        expect(methods_chunk.content).to include('def archived?')
      end

      it 'does not misclassify method lines into other sections' do
        chunks = chunker.chunk(unit)
        assoc_chunk = chunks.find { |c| c.chunk_type == :associations }
        summary = chunks.find { |c| c.chunk_type == :summary }
        expect(assoc_chunk.content).not_to include('notify_subscribers')
        expect(summary.content).not_to include('notify_subscribers')
      end
    end

    context 'with an endless model method followed by DSL declarations' do
      let(:unit) do
        build_unit(:model, 'Post', <<~RUBY)
          class Post < ApplicationRecord
            def title = super&.strip

            validates :body, presence: true

            def word_count
              body.split.size
            end
          end
        RUBY
      end

      it 'does not swallow subsequent declarations into :methods' do
        validations = chunker.chunk(unit).find { |c| c.chunk_type == :validations }
        expect(validations).not_to be_nil
        expect(validations.content).to include('validates :body')
      end

      it 'keeps both methods in the :methods chunk' do
        methods_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :methods }
        expect(methods_chunk.content).to include('def title = super&.strip')
        expect(methods_chunk.content).to include('body.split.size')
      end
    end

    context 'with a model method containing case/in pattern matching' do
      let(:unit) do
        build_unit(:model, 'Event', <<~RUBY)
          class Event < ApplicationRecord
            validates :payload, presence: true

            def dispatch
              case payload
              in { type: 'a' }
                handle_a
              in { type: 'b' }
                handle_b
              end
              audit!
            end
          end
        RUBY
      end

      it 'keeps statements after the case inside the :methods chunk' do
        methods_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :methods }
        expect(methods_chunk.content).to include('audit!')
      end

      it 'does not misclassify method lines into the :validations section' do
        validations = chunker.chunk(unit).find { |c| c.chunk_type == :validations }
        expect(validations.content).not_to include('audit!')
      end
    end

    context 'with a =begin/=end block comment inside a method (STO-3)' do
      let(:unit) do
        build_unit(:service, 'Probe', <<~RUBY)
          class Probe
            def alpha
          =begin
            embedded comment
          =end
              1
            end

            def beta
              2
            end
          end
        RUBY
      end

      it 'gives the following method its own chunk' do
        # `=begin` matched the assignment-position keyword branch, so the
        # enclosing method never closed and every later method was appended
        # to its chunk.
        types = chunker.chunk(unit).map(&:chunk_type)
        expect(types).to include(:method_alpha, :method_beta)
      end

      it 'does not swallow the following method into the commented one' do
        alpha_chunk = chunker.chunk(unit).find { |c| c.chunk_type == :method_alpha }
        expect(alpha_chunk.content).not_to include('def beta')
      end
    end
  end
end
