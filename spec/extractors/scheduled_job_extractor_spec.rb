# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/scheduled_job_extractor'

RSpec.describe CodebaseIndex::Extractors::ScheduledJobExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing schedule files gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers Solid Queue recurring.yml' do
      create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:scheduled_job)
    end

    it 'discovers Sidekiq-Cron schedule file' do
      create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:scheduled_job)
    end

    it 'discovers Whenever schedule.rb' do
      create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          runner "CleanupJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:scheduled_job)
    end

    it 'returns multiple units from a single file' do
      create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
        daily_report:
          class: ReportJob
          schedule: every day at 2am
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('scheduled:periodic_cleanup', 'scheduled:daily_report')
    end

    it 'collects units from multiple coexisting schedule files' do
      create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      create_file('config/sidekiq_cron.yml', <<~YAML)
        daily_report:
          cron: "0 0 * * *"
          class: ReportJob
      YAML

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      formats = units.map { |u| u.metadata[:schedule_format] }
      expect(formats).to contain_exactly(:solid_queue, :sidekiq_cron)
    end
  end

  # ── Solid Queue (config/recurring.yml) ─────────────────────────────

  describe 'Solid Queue format' do
    it 'extracts a basic entry' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:scheduled_job)
      expect(unit.identifier).to eq('scheduled:periodic_cleanup')
      expect(unit.metadata[:schedule_format]).to eq(:solid_queue)
      expect(unit.metadata[:job_class]).to eq('CleanupJob')
      expect(unit.metadata[:cron_expression]).to eq('every 6 hours')
    end

    it 'extracts multiple entries' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
        daily_report:
          class: ReportJob
          schedule: every day at 2am
        weekly_digest:
          class: DigestJob
          schedule: every week
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.size).to eq(3)
      expect(units.map(&:identifier)).to contain_exactly(
        'scheduled:periodic_cleanup',
        'scheduled:daily_report',
        'scheduled:weekly_digest'
      )
    end

    it 'extracts queue name' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          queue: maintenance
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.metadata[:queue]).to eq('maintenance')
    end

    it 'extracts args' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
          args:
            - 30
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.metadata[:args]).to eq([30])
    end

    it 'handles environment-nested YAML' do
      path = create_file('config/recurring.yml', <<~YAML)
        production:
          periodic_cleanup:
            class: CleanupJob
            schedule: every 6 hours
          daily_report:
            class: ReportJob
            schedule: every day at 2am
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.size).to eq(2)
      expect(units.first.metadata[:job_class]).to eq('CleanupJob')
    end

    it 'sets file_path on each unit' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.file_path).to eq(path)
    end

    it 'sets source_code with the YAML content' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.source_code).to include('CleanupJob')
    end
  end

  # ── Sidekiq-Cron (config/sidekiq_cron.yml) ─────────────────────────

  describe 'Sidekiq-Cron format' do
    it 'extracts a basic entry' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:scheduled_job)
      expect(unit.identifier).to eq('scheduled:cleanup_job')
      expect(unit.metadata[:schedule_format]).to eq(:sidekiq_cron)
      expect(unit.metadata[:job_class]).to eq('CleanupJob')
      expect(unit.metadata[:cron_expression]).to eq('0 */6 * * *')
    end

    it 'extracts multiple entries' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
        report_job:
          cron: "0 0 * * *"
          class: ReportJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.size).to eq(2)
    end

    it 'extracts queue and args' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
          queue: maintenance
          args:
            - 30
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      unit = units.first
      expect(unit.metadata[:queue]).to eq('maintenance')
      expect(unit.metadata[:args]).to eq([30])
    end

    it 'handles environment-nested YAML' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        production:
          cleanup_job:
            cron: "0 */6 * * *"
            class: CleanupJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.size).to eq(1)
      expect(units.first.metadata[:job_class]).to eq('CleanupJob')
    end
  end

  # ── Whenever (config/schedule.rb) ───────────────────────────────────

  describe 'Whenever format' do
    it 'extracts a basic every block with runner' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          runner "CleanupJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.type).to eq(:scheduled_job)
      expect(unit.metadata[:schedule_format]).to eq(:whenever)
      expect(unit.metadata[:cron_expression]).to eq('1.hour')
      expect(unit.metadata[:job_class]).to eq('CleanupJob')
    end

    it 'extracts multiple every blocks' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          runner "CleanupJob.perform_later"
        end

        every 1.day, at: '2:00 am' do
          runner "ReportJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(2)
    end

    it 'extracts job class from perform_now' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          runner "DigestJob.perform_now"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.first.metadata[:job_class]).to eq('DigestJob')
    end

    it 'detects rake task type' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          rake "reports:generate"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(1)
      expect(units.first.metadata[:command_type]).to eq(:rake)
      expect(units.first.metadata[:job_class]).to be_nil
    end

    it 'detects command type' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          command "echo 'hello'"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(1)
      expect(units.first.metadata[:command_type]).to eq(:command)
    end

    it 'detects runner type' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          runner "SomeTask.run"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.first.metadata[:command_type]).to eq(:runner)
    end

    it 'generates identifiers from frequency and index' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          runner "CleanupJob.perform_later"
        end

        every 1.day, at: '2:00 am' do
          runner "ReportJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units[0].identifier).to start_with('scheduled:')
      expect(units[1].identifier).to start_with('scheduled:')
      expect(units[0].identifier).not_to eq(units[1].identifier)
    end

    it 'extracts at option from every block' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day, at: '4:30 am' do
          runner "ReportJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.first.metadata[:cron_expression]).to include('1.day')
    end
  end

  # ── Human-readable frequency ───────────────────────────────────────

  describe 'human-readable frequency' do
    it 'humanizes "0 * * * *" to "every hour"' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        hourly_job:
          cron: "0 * * * *"
          class: HourlyJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('every hour')
    end

    it 'humanizes "0 0 * * *" to "daily at midnight"' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        daily_job:
          cron: "0 0 * * *"
          class: DailyJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('daily at midnight')
    end

    it 'humanizes "0 0 * * 0" to "weekly on Sunday"' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        weekly_job:
          cron: "0 0 * * 0"
          class: WeeklyJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('weekly on Sunday')
    end

    it 'humanizes "0 0 1 * *" to "monthly on the 1st"' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        monthly_job:
          cron: "0 0 1 * *"
          class: MonthlyJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('monthly on the 1st')
    end

    it 'passes through Solid Queue frequency as human readable' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.metadata[:frequency_human_readable]).to eq('every 6 hours')
    end

    it 'returns raw cron for unrecognized patterns' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        custom_job:
          cron: "15 3 */2 * 1-5"
          class: CustomJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('15 3 */2 * 1-5')
    end

    it 'humanizes "*/5 * * * *" to "every 5 minutes"' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        frequent_job:
          cron: "*/5 * * * *"
          class: FrequentJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.metadata[:frequency_human_readable]).to eq('every 5 minutes')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it 'links to job class when identified' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      deps = units.first.dependencies
      expect(deps.size).to eq(1)
      expect(deps.first[:type]).to eq(:job)
      expect(deps.first[:target]).to eq('CleanupJob')
      expect(deps.first[:via]).to eq(:scheduled)
    end

    it 'has empty dependencies when no job class is found' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.hour do
          rake "cache:clear"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.first.dependencies).to eq([])
    end

    it 'links Whenever runner job class' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          runner "NotificationJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      deps = units.first.dependencies
      expect(deps.size).to eq(1)
      expect(deps.first[:type]).to eq(:job)
      expect(deps.first[:target]).to eq('NotificationJob')
      expect(deps.first[:via]).to eq(:scheduled)
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'returns empty array for empty YAML file' do
      path = create_file('config/recurring.yml', '')
      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units).to eq([])
    end

    it 'returns empty array for invalid YAML' do
      path = create_file('config/recurring.yml', 'not: valid: yaml: {{{}}}')
      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units).to eq([])
    end

    it 'returns empty array for missing class key in YAML entries' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.size).to eq(1)
      expect(units.first.metadata[:job_class]).to be_nil
    end

    it 'handles read errors gracefully' do
      units = described_class.new.extract_scheduled_job_file('/nonexistent/path.yml', :solid_queue)
      expect(units).to eq([])
    end

    it 'returns empty array for empty Whenever file' do
      path = create_file('config/schedule.rb', '')
      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units).to eq([])
    end

    it 'returns empty array for Whenever file with no every blocks' do
      path = create_file('config/schedule.rb', <<~RUBY)
        set :output, '/var/log/cron.log'
        env :PATH, '/usr/local/bin'
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units).to eq([])
    end

    it 'handles YAML with only comments' do
      path = create_file('config/recurring.yml', <<~YAML)
        # This is a comment
        # Another comment
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units).to eq([])
    end

    it 'skips entries without a hash value' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
        invalid_entry: "just a string"
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('scheduled:cleanup_job')
    end
  end

  # ── Identifier prefixing ───────────────────────────────────────────

  describe 'identifier format' do
    it 'prefixes identifiers with "scheduled:"' do
      path = create_file('config/recurring.yml', <<~YAML)
        periodic_cleanup:
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      expect(units.first.identifier).to eq('scheduled:periodic_cleanup')
    end

    it 'prefixes Sidekiq-Cron identifiers' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        cleanup_job:
          cron: "0 */6 * * *"
          class: CleanupJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.first.identifier).to eq('scheduled:cleanup_job')
    end
  end
end
