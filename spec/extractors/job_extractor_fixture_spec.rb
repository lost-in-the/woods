# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/extractors/job_extractor'

RSpec.describe CodebaseIndex::Extractors::JobExtractor, 'fixture specs' do
  include_context 'extractor setup'

  # ── Namespaced Jobs ───────────────────────────────────────────────────

  describe 'namespaced job (Admin::CleanupJob)' do
    it 'extracts a deeply namespaced job with full metadata' do
      path = create_file('app/jobs/admin/cleanup_job.rb', <<~RUBY)
        class Admin::CleanupJob < ApplicationJob
          queue_as :maintenance

          def perform(older_than: 30)
            Record.where('created_at < ?', older_than.days.ago).delete_all
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Admin::CleanupJob')
      expect(unit.namespace).to eq('Admin')
      expect(unit.metadata[:queue]).to eq('maintenance')
      expect(unit.metadata[:job_type]).to eq(:active_job)
    end
  end

  # ── Multiple Queue Configurations ─────────────────────────────────────

  describe 'job with sidekiq_options and queue' do
    it 'extracts sidekiq options alongside queue' do
      path = create_file('app/workers/bulk_import_worker.rb', <<~RUBY)
        class BulkImportWorker
          include Sidekiq::Worker
          sidekiq_options queue: :bulk, retry: 3, dead: false

          def perform(file_path, batch_size = 1000)
            CSV.foreach(file_path).each_slice(batch_size) do |rows|
              ImportService.call(rows)
            end
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      expect(unit).not_to be_nil
      expect(unit.metadata[:queue]).to eq('bulk')
      expect(unit.metadata[:sidekiq_options]).to include(queue: ':bulk')
      expect(unit.metadata[:retry_config][:sidekiq_retries]).to eq('3')
      expect(unit.metadata[:perform_params].size).to eq(2)
      expect(unit.metadata[:perform_params][1][:has_default]).to be true
    end
  end

  # ── Retry Configuration ───────────────────────────────────────────────

  describe 'job with multiple retry_on and discard_on' do
    it 'extracts all error handling config' do
      path = create_file('app/jobs/resilient_job.rb', <<~RUBY)
        class ResilientJob < ApplicationJob
          queue_as :default

          retry_on Net::OpenTimeout, wait: 5, attempts: 3
          retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 10
          discard_on ActiveJob::DeserializationError
          discard_on CustomGoneError

          def perform(resource_id)
            Resource.find(resource_id).sync!
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      expect(unit.metadata[:retry_on]).to include('Net::OpenTimeout', 'ActiveRecord::Deadlocked')
      expect(unit.metadata[:discard_on]).to include('ActiveJob::DeserializationError', 'CustomGoneError')
    end
  end

  # ── Edge: Empty Job File ──────────────────────────────────────────────

  describe 'empty job file' do
    it 'returns nil for an empty file' do
      path = create_file('app/jobs/empty_job.rb', '')

      unit = described_class.new.extract_job_file(path)
      expect(unit).to be_nil
    end
  end

  # ── Edge: Job Without perform Method ──────────────────────────────────

  describe 'job without perform method' do
    it 'returns nil for a class with no job indicators' do
      path = create_file('app/jobs/not_a_job.rb', <<~RUBY)
        class NotAJob
          def call
            true
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      expect(unit).to be_nil
    end
  end

  # ── Job with Callbacks and Concurrency Controls ───────────────────────

  describe 'job with callbacks and concurrency controls' do
    it 'extracts callbacks and concurrency options' do
      path = create_file('app/jobs/tracked_sync_job.rb', <<~RUBY)
        class TrackedSyncJob < ApplicationJob
          queue_as :sync

          before_perform :acquire_lock
          after_perform :release_lock
          around_perform :measure_duration

          def perform(account_id)
            Account.find(account_id).full_sync!
          end

          private

          def acquire_lock
            Redis.current.set("sync_lock:\#{self.class.name}", true)
          end

          def release_lock
            Redis.current.del("sync_lock:\#{self.class.name}")
          end

          def measure_duration
            start = Time.now
            yield
            Rails.logger.info("Sync took \#{Time.now - start}s")
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)

      callbacks = unit.metadata[:callbacks]
      types = callbacks.map { |c| c[:type] }
      expect(types).to include('before_perform', 'after_perform', 'around_perform')
      expect(callbacks.find { |c| c[:type] == 'before_perform' }[:method]).to eq('acquire_lock')
    end
  end

  # ── LOC Counting ──────────────────────────────────────────────────────

  describe 'LOC metadata' do
    it 'counts non-blank non-comment lines' do
      path = create_file('app/jobs/counted_job.rb', <<~RUBY)
        # This is a comment
        class CountedJob < ApplicationJob
          # Another comment

          def perform(id)
            process(id)
          end
        end
      RUBY

      unit = described_class.new.extract_job_file(path)
      # Lines with code: class, def perform, process(id), 2x end = 5
      expect(unit.metadata[:loc]).to eq(5)
    end
  end
end
