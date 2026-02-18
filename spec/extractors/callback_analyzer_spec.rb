# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extractors/callback_analyzer'

RSpec.describe CodebaseIndex::Extractors::CallbackAnalyzer do
  let(:column_names) { %w[email name status role] }

  def build_analyzer(source, columns: column_names)
    described_class.new(
      source_code: source,
      column_names: columns
    )
  end

  def make_callback(filter:, type: :before_save, kind: :before, conditions: {})
    { type: type, filter: filter, kind: kind, conditions: conditions }
  end

  # ── Column write detection ─────────────────────────────────────

  describe 'column write detection' do
    it 'detects self.col = assignment' do
      source = <<~RUBY
        class User
          def normalize_email
            self.email = email.downcase.strip
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'normalize_email'))
      expect(result[:side_effects][:columns_written]).to include('email')
    end

    it 'detects update_column calls' do
      source = <<~RUBY
        class User
          def touch_status
            update_column(:status, 'active')
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'touch_status'))
      expect(result[:side_effects][:columns_written]).to include('status')
    end

    it 'detects update_columns calls' do
      source = <<~RUBY
        class User
          def activate
            update_columns(status: 'active', role: 'member')
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'activate'))
      expect(result[:side_effects][:columns_written]).to include('status', 'role')
    end

    it 'detects write_attribute calls' do
      source = <<~RUBY
        class User
          def set_name
            write_attribute(:name, 'default')
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'set_name'))
      expect(result[:side_effects][:columns_written]).to include('name')
    end

    it 'detects assign_attributes calls' do
      source = <<~RUBY
        class User
          def set_defaults
            assign_attributes(email: 'none@example.com', status: 'pending')
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'set_defaults'))
      expect(result[:side_effects][:columns_written]).to include('email', 'status')
    end

    it 'ignores columns not in column_names list' do
      source = <<~RUBY
        class User
          def set_foo
            self.unknown_column = 'value'
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'set_foo'))
      expect(result[:side_effects][:columns_written]).to be_empty
    end
  end

  # ── Job enqueue detection ──────────────────────────────────────

  describe 'job enqueue detection' do
    it 'detects perform_later calls' do
      source = <<~RUBY
        class User
          def enqueue_welcome
            WelcomeJob.perform_later(id)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'enqueue_welcome'))
      expect(result[:side_effects][:jobs_enqueued]).to include('WelcomeJob')
    end

    it 'detects perform_async calls' do
      source = <<~RUBY
        class User
          def sync_data
            SyncJob.perform_async(id)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'sync_data'))
      expect(result[:side_effects][:jobs_enqueued]).to include('SyncJob')
    end
  end

  # ── Service call detection ─────────────────────────────────────

  describe 'service call detection' do
    it 'detects Service.call patterns' do
      source = <<~RUBY
        class User
          def process_signup
            SignupService.call(user: self)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'process_signup'))
      expect(result[:side_effects][:services_called]).to include('SignupService')
    end

    it 'detects Service.new patterns' do
      source = <<~RUBY
        class User
          def validate_data
            ValidationService.new(self).run
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'validate_data'))
      expect(result[:side_effects][:services_called]).to include('ValidationService')
    end
  end

  # ── Mailer detection ───────────────────────────────────────────

  describe 'mailer detection' do
    it 'detects Mailer method calls' do
      source = <<~RUBY
        class User
          def send_welcome
            UserMailer.welcome(self).deliver_later
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'send_welcome'))
      expect(result[:side_effects][:mailers_triggered]).to include('UserMailer')
    end
  end

  # ── Database read detection ────────────────────────────────────

  describe 'database read detection' do
    it 'detects find calls' do
      source = <<~RUBY
        class User
          def load_related
            Post.find(post_id)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'load_related'))
      expect(result[:side_effects][:database_reads]).to include('find')
    end

    it 'detects where calls' do
      source = <<~RUBY
        class User
          def check_siblings
            User.where(email: email)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'check_siblings'))
      expect(result[:side_effects][:database_reads]).to include('where')
    end

    it 'detects pluck calls' do
      source = <<~RUBY
        class User
          def load_names
            User.pluck(:name)
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'load_names'))
      expect(result[:side_effects][:database_reads]).to include('pluck')
    end

    it 'detects first and last calls' do
      source = <<~RUBY
        class User
          def find_neighbor
            User.where(status: 'active').first
            User.where(status: 'active').last
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'find_neighbor'))
      expect(result[:side_effects][:database_reads]).to include('first', 'last')
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────

  describe 'edge cases' do
    it 'returns empty side_effects for proc/lambda callbacks' do
      source = <<~RUBY
        class User
          before_save -> { self.email = email.downcase }
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: '#<Proc:0x00007f>'))
      expect(result[:side_effects]).to eq(
        columns_written: [], jobs_enqueued: [], services_called: [],
        mailers_triggered: [], database_reads: [], operations: []
      )
    end

    it 'returns empty side_effects when method is not found in source' do
      source = <<~RUBY
        class User
          def other_method
            self.email = 'test'
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'nonexistent_method'))
      expect(result[:side_effects]).to eq(
        columns_written: [], jobs_enqueued: [], services_called: [],
        mailers_triggered: [], database_reads: [], operations: []
      )
    end

    it 'preserves the original callback hash fields' do
      source = <<~RUBY
        class User
          def do_stuff
            self.email = 'test'
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      callback = make_callback(filter: 'do_stuff', type: :before_save, kind: :before, conditions: { if: :active? })
      result = analyzer.analyze(callback)
      expect(result[:type]).to eq(:before_save)
      expect(result[:filter]).to eq('do_stuff')
      expect(result[:kind]).to eq(:before)
      expect(result[:conditions]).to eq({ if: :active? })
      expect(result).to have_key(:side_effects)
    end

    it 'finds callback methods defined in inlined concern source' do
      source = <<~RUBY
        class User < ApplicationRecord
          def regular_method
            # nothing
          end

          # --- inlined from Trackable ---
          def set_tracking_status
            self.status = 'tracked'
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'set_tracking_status'))
      expect(result[:side_effects][:columns_written]).to include('status')
    end
  end

  # ── Multiple side effects ──────────────────────────────────────

  describe 'multiple side effects in one callback' do
    it 'detects all side effect types in a single callback method' do
      source = <<~RUBY
        class User
          def after_create_actions
            self.status = 'active'
            WelcomeJob.perform_later(id)
            AuditService.call(user: self)
            NotificationMailer.welcome(self).deliver_later
            Post.where(user_id: id)
          end
        end
      RUBY

      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'after_create_actions', type: :after_create))

      effects = result[:side_effects]
      expect(effects[:columns_written]).to include('status')
      expect(effects[:jobs_enqueued]).to include('WelcomeJob')
      expect(effects[:services_called]).to include('AuditService')
      expect(effects[:mailers_triggered]).to include('NotificationMailer')
      expect(effects[:database_reads]).to include('where')
    end
  end

  # ── Operations from OperationExtractor ─────────────────────────

  describe 'operations extraction' do
    it 'includes operations from OperationExtractor' do
      source = <<~RUBY
        class User
          def process
            SomeClass.compute
          end
        end
      RUBY
      analyzer = build_analyzer(source)
      result = analyzer.analyze(make_callback(filter: 'process'))
      ops = result[:side_effects][:operations]
      expect(ops).to be_an(Array)
      expect(ops).not_to be_empty
    end
  end
end
