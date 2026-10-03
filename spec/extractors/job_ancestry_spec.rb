# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/job_ancestry'

RSpec.describe Woods::Extractors::JobAncestry do
  include_context 'extractor setup'

  let(:gem_root) { Dir.mktmpdir('job-ancestry-gem') }

  before do
    stub_const('AncestryJobs', Module.new)
    stub_const('Sidekiq', Module.new)
    stand_in = File.join(gem_root, 'sidekiq.rb')
    File.write(stand_in, <<~RUBY)
      module Sidekiq
        module Job; end
        Worker = Job
      end

      module AncestryJobs
        class GemWorker
          include Sidekiq::Job
        end
      end
    RUBY
    load stand_in
  end

  after { FileUtils.rm_rf(gem_root) }

  def declare(relative, body)
    path = create_file(relative, "module AncestryJobs\n#{body}\nend\n")
    load path
    path
  end

  describe '.job_class?' do
    it 'recognizes Sidekiq includers and ActiveJob descendants by ancestry alone' do
      stub_const('ActiveJob::Base', Class.new)
      declare('app/models/ancestry_jobs/ledger_worker.rb', "class LedgerWorker\n  include Sidekiq::Worker\nend")
      declare('app/models/ancestry_jobs/ledger_job.rb', 'class LedgerJob < ActiveJob::Base; end')
      declare('app/models/ancestry_jobs/ledger_rate.rb', 'class LedgerRate; end')

      expect(described_class.job_class?(AncestryJobs::LedgerWorker)).to be(true)
      expect(described_class.job_class?(AncestryJobs::LedgerJob)).to be(true)
      expect(described_class.job_class?(AncestryJobs::LedgerRate)).to be(false)
      expect(described_class.job_class?(AncestryJobs)).to be(false)
    end

    it 'ignores a class-level include? override' do
      declare('app/models/ancestry_jobs/registry.rb', "class Registry\n  def self.include?(*) = true\nend")

      expect(described_class.job_class?(AncestryJobs::Registry)).to be(false)
    end
  end

  describe '.admitted?' do
    let(:app_root) { rails_root.to_s }

    it 'admits an application job class declared by its definition file' do
      declare('app/models/ancestry_jobs/import_manager.rb', "class ImportManager\n  include Sidekiq::Worker\nend")

      expect(described_class.admitted?(AncestryJobs::ImportManager, app_root: app_root)).to be(true)
    end

    it 'refuses a job class defined outside the application root' do
      expect(described_class.admitted?(AncestryJobs::GemWorker, app_root: app_root)).to be(false)
    end

    it 'refuses a generated job class whose definition site does not declare it' do
      declare('lib/ancestry_jobs/generator.rb', <<~RUBY)
        module Generator
          def self.build(owner) = owner.const_set(:GeneratedWorker, Class.new { include Sidekiq::Worker })
        end
      RUBY
      AncestryJobs::Generator.build(AncestryJobs)
      allow(logger).to receive(:debug)

      expect(described_class.admitted?(AncestryJobs::GeneratedWorker, app_root: app_root)).to be(false)
      expect(logger).to have_received(:debug).with(/AncestryJobs::GeneratedWorker/)
    end

    it 'refuses a class without job ancestry' do
      declare('app/models/ancestry_jobs/ledger_rate.rb', 'class LedgerRate; end')

      expect(described_class.admitted?(AncestryJobs::LedgerRate, app_root: app_root)).to be(false)
    end
  end
end
