# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/job_extractor'

RSpec.describe CodebaseIndex::Extractors::JobExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it_behaves_like 'handles missing directories'
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers job files in app/jobs/' do
      create_file('app/jobs/process_order_job.rb', <<~RUBY)
        class ProcessOrderJob < ApplicationJob
          queue_as :default

          def perform(order_id)
            Order.find(order_id).process!
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('ProcessOrderJob')
      expect(units.first.type).to eq(:job)
    end

    it 'discovers worker files in app/workers/' do
      create_file('app/workers/sync_worker.rb', <<~RUBY)
        class SyncWorker
          include Sidekiq::Worker

          def perform(user_id)
            User.find(user_id).sync!
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('SyncWorker')
    end

    it 'discovers files in app/sidekiq/' do
      create_file('app/sidekiq/cleanup_job.rb', <<~RUBY)
        class CleanupJob
          include Sidekiq::Job

          def perform
            TempFile.expired.delete_all
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('CleanupJob')
    end

    it 'skips non-job files' do
      create_file('app/jobs/job_helpers.rb', <<~RUBY)
        module JobHelpers
          def retry_with_backoff
            sleep(1)
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units).to be_empty
    end
  end

  # ── job_file? detection ──────────────────────────────────────────────

  describe 'job_file? detection' do
    it 'recognizes ApplicationJob subclass' do
      path = create_file('app/jobs/notify_job.rb', <<~RUBY)
        class NotifyJob < ApplicationJob
          def perform(user_id)
            UserMailer.welcome(user_id).deliver_now
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:job_type]).to eq(:active_job)
    end

    it 'recognizes ActiveJob::Base subclass' do
      path = create_file('app/jobs/base_job.rb', <<~RUBY)
        class BaseJob < ActiveJob::Base
          def perform
            true
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:job_type]).to eq(:active_job)
    end

    it 'recognizes Sidekiq::Worker include' do
      path = create_file('app/workers/legacy_worker.rb', <<~RUBY)
        class LegacyWorker
          include Sidekiq::Worker

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:job_type]).to eq(:sidekiq)
    end

    it 'recognizes Sidekiq::Job include' do
      path = create_file('app/workers/modern_worker.rb', <<~RUBY)
        class ModernWorker
          include Sidekiq::Job

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:job_type]).to eq(:sidekiq)
    end

    it 'recognizes plain def perform' do
      path = create_file('app/jobs/simple_job.rb', <<~RUBY)
        class SimpleJob
          def perform(data)
            process(data)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).not_to be_nil
    end

    it 'rejects non-job files' do
      path = create_file('app/jobs/helpers.rb', <<~RUBY)
        class JobHelper
          def format_data(data)
            data.to_json
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).to be_nil
    end
  end

  # ── extract_job_file ─────────────────────────────────────────────────

  describe '#extract_job_file' do
    it 'extracts ActiveJob metadata' do
      path = create_file('app/jobs/process_order_job.rb', <<~RUBY)
        class ProcessOrderJob < ApplicationJob
          queue_as :critical

          retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3
          discard_on ActiveJob::DeserializationError

          before_perform :log_start
          after_perform :log_end

          def perform(order_id, notify: true)
            order = Order.find(order_id)
            order.process!
            OrderMailer.confirmation(order).deliver_later if notify
          end

          private

          def log_start
            Rails.logger.info("Starting order processing")
          end

          def log_end
            Rails.logger.info("Finished order processing")
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:job)
      expect(unit.identifier).to eq('ProcessOrderJob')
      expect(unit.metadata[:job_type]).to eq(:active_job)
      expect(unit.metadata[:queue]).to eq('critical')
      expect(unit.metadata[:discard_on]).to include('ActiveJob::DeserializationError')
      expect(unit.metadata[:retry_on]).to include('ActiveRecord::Deadlocked')
      expect(unit.metadata[:callbacks]).not_to be_empty
    end

    it 'extracts Sidekiq metadata' do
      path = create_file('app/workers/data_sync_worker.rb', <<~RUBY)
        class DataSyncWorker
          include Sidekiq::Worker
          sidekiq_options queue: :low, retry: 5

          def perform(user_id, options = {})
            User.find(user_id).sync!(options)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      expect(unit).not_to be_nil
      expect(unit.type).to eq(:job)
      expect(unit.identifier).to eq('DataSyncWorker')
      expect(unit.metadata[:job_type]).to eq(:sidekiq)
      expect(unit.metadata[:queue]).to eq('low')
      expect(unit.metadata[:sidekiq_options]).to include(queue: ':low')
    end

    it 'annotates source with header' do
      path = create_file('app/jobs/notify_job.rb', <<~RUBY)
        class NotifyJob < ApplicationJob
          queue_as :default

          def perform(user_id)
            true
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.source_code).to include('Job: NotifyJob')
      expect(unit.source_code).to include('Type:')
      expect(unit.source_code).to include('Queue:')
    end

    it 'handles read errors gracefully' do
      unit = described_class.new.extract_job_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end

  # ── Queue Extraction ─────────────────────────────────────────────────

  describe 'queue extraction' do
    it 'extracts ActiveJob queue_as' do
      path = create_file('app/jobs/mailer_job.rb', <<~RUBY)
        class MailerJob < ApplicationJob
          queue_as :mailers

          def perform(email_id)
            Email.find(email_id).deliver
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:queue]).to eq('mailers')
    end

    it 'extracts Sidekiq queue from sidekiq_options' do
      path = create_file('app/workers/bulk_worker.rb', <<~RUBY)
        class BulkWorker
          include Sidekiq::Worker
          sidekiq_options queue: :bulk

          def perform(ids)
            ids.each { |id| process(id) }
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:queue]).to eq('bulk')
    end

    it 'defaults to nil when no queue specified' do
      path = create_file('app/jobs/simple_job.rb', <<~RUBY)
        class SimpleJob < ApplicationJob
          def perform
            true
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:queue]).to be_nil
    end
  end

  # ── Retry Config ─────────────────────────────────────────────────────

  describe 'retry config extraction' do
    it 'extracts ActiveJob retry_on configuration' do
      path = create_file('app/jobs/flaky_job.rb', <<~RUBY)
        class FlakyJob < ApplicationJob
          retry_on Net::OpenTimeout, wait: 10, attempts: 3

          def perform(url)
            Net::HTTP.get(URI(url))
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      retry_config = unit.metadata[:retry_config]
      expect(retry_config[:retry_on]).not_to be_empty
      expect(retry_config[:retry_on].first[:error]).to eq('Net')
    end

    it 'extracts Sidekiq retry count' do
      path = create_file('app/workers/retry_worker.rb', <<~RUBY)
        class RetryWorker
          include Sidekiq::Worker
          sidekiq_options retry: 10

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:retry_config][:sidekiq_retries]).to eq('10')
    end

    it 'extracts discard_on errors' do
      path = create_file('app/jobs/safe_job.rb', <<~RUBY)
        class SafeJob < ApplicationJob
          discard_on ActiveJob::DeserializationError
          discard_on CustomError

          def perform(id)
            Record.find(id).process!
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:discard_on]).to include('ActiveJob::DeserializationError', 'CustomError')
    end
  end

  # ── Perform Params ───────────────────────────────────────────────────

  describe 'extract_perform_params' do
    it 'extracts regular parameters' do
      path = create_file('app/jobs/basic_job.rb', <<~RUBY)
        class BasicJob < ApplicationJob
          def perform(user_id, action)
            User.find(user_id).send(action)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      params = unit.metadata[:perform_params]
      expect(params.size).to eq(2)
      expect(params[0][:name]).to eq('user_id')
      expect(params[0][:splat]).to be_nil
      expect(params[1][:name]).to eq('action')
    end

    it 'extracts splat parameters' do
      path = create_file('app/jobs/varargs_job.rb', <<~RUBY)
        class VarargsJob < ApplicationJob
          def perform(*args)
            args.each { |a| process(a) }
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      params = unit.metadata[:perform_params]
      expect(params.first[:name]).to eq('args')
      expect(params.first[:splat]).to eq(:single)
    end

    it 'extracts double splat parameters' do
      path = create_file('app/jobs/kwargs_job.rb', <<~RUBY)
        class KwargsJob < ApplicationJob
          def perform(**options)
            process(options)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      params = unit.metadata[:perform_params]
      expect(params.first[:name]).to eq('options')
      expect(params.first[:splat]).to eq(:double)
    end

    it 'extracts parameters with defaults' do
      path = create_file('app/jobs/default_job.rb', <<~RUBY)
        class DefaultJob < ApplicationJob
          def perform(user_id, notify = true)
            User.find(user_id).process!
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      params = unit.metadata[:perform_params]
      expect(params[0][:has_default]).to be false
      expect(params[1][:has_default]).to be true
    end

    it 'returns empty for parameterless perform' do
      path = create_file('app/jobs/noop_job.rb', <<~RUBY)
        class NoopJob < ApplicationJob
          def perform
            cleanup!
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.metadata[:perform_params]).to eq([])
    end
  end

  # ── Callbacks ────────────────────────────────────────────────────────

  describe 'callback extraction' do
    it 'extracts before_perform callbacks' do
      path = create_file('app/jobs/guarded_job.rb', <<~RUBY)
        class GuardedJob < ApplicationJob
          before_perform :validate_input

          def perform(data)
            process(data)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      callbacks = unit.metadata[:callbacks]
      expect(callbacks).to include(hash_including(type: 'before_perform', method: 'validate_input'))
    end

    it 'extracts after_perform callbacks' do
      path = create_file('app/jobs/logging_job.rb', <<~RUBY)
        class LoggingJob < ApplicationJob
          after_perform :notify_complete

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      callbacks = unit.metadata[:callbacks]
      expect(callbacks).to include(hash_including(type: 'after_perform', method: 'notify_complete'))
    end

    it 'extracts around_perform callbacks' do
      path = create_file('app/jobs/timed_job.rb', <<~RUBY)
        class TimedJob < ApplicationJob
          around_perform :measure_time

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      callbacks = unit.metadata[:callbacks]
      expect(callbacks).to include(hash_including(type: 'around_perform', method: 'measure_time'))
    end

    it 'extracts enqueue callbacks' do
      path = create_file('app/jobs/tracked_job.rb', <<~RUBY)
        class TrackedJob < ApplicationJob
          before_enqueue :check_quota
          after_enqueue :log_enqueue

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      callbacks = unit.metadata[:callbacks]
      types = callbacks.map { |c| c[:type] }
      expect(types).to include('before_enqueue', 'after_enqueue')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_job_file,
                    'app/jobs/order_job.rb',
                    <<~RUBY
                      class OrderJob < ApplicationJob
                        def perform(order_id)
                          order = Order.find(order_id)
                          PaymentService.charge(order)
                          ReceiptMailer.send_receipt(order).deliver_later
                        end
                      end
                    RUBY

    it 'detects HTTP dependencies' do
      path = create_file('app/jobs/webhook_job.rb', <<~RUBY)
        class WebhookJob < ApplicationJob
          def perform(url, payload)
            Faraday.post(url, payload)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      http_deps = unit.dependencies.select { |d| d[:target] == :http_api }
      expect(http_deps).not_to be_empty
    end

    it 'detects Redis dependencies' do
      path = create_file('app/jobs/cache_job.rb', <<~RUBY)
        class CacheJob < ApplicationJob
          def perform(key)
            Redis.current.del(key)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      redis_deps = unit.dependencies.select { |d| d[:target] == :redis }
      expect(redis_deps).not_to be_empty
    end

    it 'detects service dependencies via shared scanner' do
      path = create_file('app/jobs/flow_job.rb', <<~RUBY)
        class FlowJob < ApplicationJob
          def perform(order_id)
            CheckoutService.call(order_id)
            ShippingService.new.execute(order_id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      targets = service_deps.map { |d| d[:target] }
      expect(targets).to include('CheckoutService', 'ShippingService')
    end
  end

  # ── Namespaced Jobs ──────────────────────────────────────────────────

  describe 'namespaced jobs' do
    it 'extracts namespace' do
      path = create_file('app/jobs/billing/invoice_job.rb', <<~RUBY)
        class Billing::InvoiceJob < ApplicationJob
          def perform(invoice_id)
            Invoice.find(invoice_id).send!
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit.identifier).to eq('Billing::InvoiceJob')
      expect(unit.namespace).to eq('Billing')
    end
  end

  # ── Error Handling ───────────────────────────────────────────────────

  describe 'error handling' do
    it 'handles read errors gracefully' do
      unit = described_class.new.extract_job_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end
  end
end
