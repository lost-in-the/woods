# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/object/blank'
require 'woods/model_name_cache'
require 'woods/extractors/scheduled_job_extractor'

RSpec.describe Woods::Extractors::ScheduledJobExtractor do
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

  describe 'schedule identity allocation' do
    def schedules(first_name: 'cleanup')
      create_file('config/recurring.yml', "#{first_name}:\n  class: CleanupJob\n  schedule: every day\n")
      create_file('config/sidekiq_cron.yml', "cleanup:\n  class: OtherJob\n  cron: '0 * * * *'\n")
    end

    it 'qualifies every conflicting format while preserving each task and job' do
      schedules
      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to contain_exactly('scheduled:solid_queue:cleanup',
                                                         'scheduled:sidekiq_cron:cleanup')
      expect(units.map { |unit| unit.metadata[:task_name] }).to eq(%w[cleanup cleanup])
      expect(units.map { |unit| unit.dependencies.first[:target] }).to eq(%w[CleanupJob OtherJob])
    end

    it 'uses the same identifiers through the file entry point' do
      schedules
      extractor = described_class.new
      units = extractor.extract_scheduled_job_file(Rails.root.join('config/recurring.yml').to_s, :solid_queue)
      expect(units.map(&:identifier)).to eq(['scheduled:solid_queue:cleanup'])
    end

    it 'reserves unique legacy names before allocating collision names' do
      schedules
      create_file('config/schedule.rb', "every 1.hour do\n  runner 'CleanupJob.perform_later'\nend\n")
      File.open(Rails.root.join('config/recurring.yml'), 'a') do |file|
        file.write("solid_queue:cleanup:\n  class: ReservedJob\n  schedule: every day\n")
      end
      units = described_class.new.extract_all
      expect(units.map(&:identifier).uniq.size).to eq(4)
      expect(units.find { |unit| unit.metadata[:job_class] == 'ReservedJob' }.identifier)
        .to eq('scheduled:solid_queue:cleanup')
      expect(units.find { |unit| unit.metadata[:schedule_format] == :whenever }.identifier)
        .to eq('scheduled:whenever_cleanup_job_0')
    end

    it 'allocates the same names when schedule enumeration order changes' do
      schedules
      extractor = described_class.new
      expected = extractor.extract_all.map { |unit| [unit.identifier, unit.metadata] }.sort_by(&:first)
      files = extractor.instance_variable_get(:@schedule_files)
      extractor.instance_variable_set(:@schedule_files, files.to_a.reverse.to_h)
      expect(extractor.extract_all.map { |unit| [unit.identifier, unit.metadata] }.sort_by(&:first)).to eq(expected)
    end

    it 'restores the legacy identifier after the conflicting format is removed' do
      schedules
      File.unlink(Rails.root.join('config/sidekiq_cron.yml'))
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['scheduled:cleanup'])
    end

    it 'refuses names that normalize to the same identity inside one format' do
      create_file('config/recurring.yml',
                  "1:\n  class: FirstJob\n  schedule: daily\n'1':\n  class: SecondJob\n  schedule: weekly\n")
      expect { described_class.new.extract_all }.to raise_error(ArgumentError, /same-format schedule/)
    end
  end

  # ── Solid Queue (config/recurring.yml) ─────────────────────────────

  describe 'Solid Queue format' do
    it 'evaluates recurring ERB with the schedule filename and preserves raw source' do
      create_file('config/schedule_values.rb', 'WOODS_SCHEDULE_FREQUENCY = "every 7 hours"')
      path = create_file('config/recurring.yml', <<~YAML)
        <% require_relative "schedule_values" %>
        <% if Rails.env.to_s == "test" %>
        cleanup:
          class: CleanupJob
          schedule: <%= WOODS_SCHEDULE_FREQUENCY %>
        <% end %>
      YAML
      allow(Rails).to receive(:env).and_return('test')

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to eq(['scheduled:cleanup'])
      expect(units.first.metadata[:cron_expression]).to eq('every 7 hours')
      expect(units.first.source_code).to eq(File.read(path))
    ensure
      Object.send(:remove_const, :WOODS_SCHEDULE_FREQUENCY) if Object.const_defined?(:WOODS_SCHEDULE_FREQUENCY)
    end

    it 'renders recurring configuration on Rails versions without ConfigurationFile' do
      hide_const('ActiveSupport::ConfigurationFile')
      create_file('config/legacy_schedule_settings.rb', 'WOODS_LEGACY_FREQUENCY = "every 7 hours"')
      create_file('config/recurring.yml', <<~YAML)
        <% require_relative "legacy_schedule_settings" %>
        production: &production
          cleanup:
            class: CleanupJob
            schedule: <%= WOODS_LEGACY_FREQUENCY %>
        test: *production
      YAML
      expect(described_class.new.extract_all.first.metadata[:cron_expression]).to eq('every 7 hours')
    ensure
      Object.send(:remove_const, :WOODS_LEGACY_FREQUENCY) if Object.const_defined?(:WOODS_LEGACY_FREQUENCY)
    end

    it 'logs ERB runtime failures and omits the broken recurring file' do
      path = create_file('config/recurring.yml', '<% raise "broken schedule" %>')
      expect(Rails.logger).to receive(:error).with(/#{Regexp.escape(path)}: broken schedule/)
      expect(described_class.new.extract_all).to eq([])
    end

    ['<% if %>', '<% require_relative "missing_schedule_helper" %>'].each do |source|
      it "logs invalid ERB or missing required configuration: #{source}" do
        path = create_file('config/recurring.yml', source)
        expect(Rails.logger).to receive(:error).with(/#{Regexp.escape(path)}/)
        expect(described_class.new.extract_all).to eq([])
      end
    end

    it 'selects custom environment sections and respects an empty active section' do
      path = create_file('config/recurring.yml', <<~YAML)
        production: &production
          cleanup:
            class: CleanupJob
            schedule: every hour
        beta: {}
        development: *production
      YAML
      allow(Rails).to receive(:env).and_return('development')
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['scheduled:cleanup'])
      allow(Rails).to receive(:env).and_return('beta')
      expect(described_class.new.extract_all).to eq([])
      allow(Rails).to receive(:env).and_return('test')
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['scheduled:cleanup'])
      expect(File).to exist(path)
    end

    it 'treats null environment sections as empty without hiding other environments' do
      create_file('config/recurring.yml', <<~YAML)
        production:
          cleanup:
            class: CleanupJob
            schedule: every hour
        test:
      YAML
      allow(Rails).to receive(:env).and_return('production')
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['scheduled:cleanup'])
      allow(Rails).to receive(:env).and_return('test')
      expect(described_class.new.extract_all).to eq([])
    end

    it 'does not unwrap flat tasks named after environments or with nested arguments' do
      create_file('config/recurring.yml', <<~YAML)
        production:
          class: CleanupJob
          schedule: every hour
          args:
            options:
              enabled: true
      YAML
      allow(Rails).to receive(:env).and_return('production')
      expect(described_class.new.extract_all.map(&:identifier)).to eq(['scheduled:production'])
    end

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

    it 'unwraps the current environment, not whichever comes first (EXTB-19)' do
      # `data.values.first` indexed the development schedule and dropped
      # production entirely whenever development was listed first.
      path = create_file('config/recurring.yml', <<~YAML)
        development:
          dev_only:
            class: DevJob
            schedule: every 1 minute
        test:
          prod_cleanup:
            class: CleanupJob
            schedule: every 6 hours
      YAML

      allow(Rails).to receive(:env).and_return('test')
      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)

      expect(units.map(&:identifier)).to eq(['scheduled:prod_cleanup'])
    end

    it 'falls back to the first environment when the current one is absent (EXTB-19)' do
      path = create_file('config/recurring.yml', <<~YAML)
        development:
          dev_only:
            class: DevJob
            schedule: every 1 minute
      YAML

      allow(Rails).to receive(:env).and_return('test')
      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)

      expect(units.map(&:identifier)).to eq(['scheduled:dev_only'])
    end

    # #203 — without aliases: true, Psych 4+ raises AliasesNotEnabled on any
    # schedule file using anchors, and the rescue silently dropped the file.
    it 'extracts schedule files that use YAML anchors and aliases' do
      path = create_file('config/recurring.yml', <<~YAML)
        defaults: &defaults
          queue: maintenance
        periodic_cleanup:
          <<: *defaults
          class: CleanupJob
          schedule: every 6 hours
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :solid_queue)
      cleanup = units.find { |u| u.identifier == 'scheduled:periodic_cleanup' }

      expect(cleanup).not_to be_nil
      expect(cleanup.metadata[:job_class]).to eq('CleanupJob')
      expect(cleanup.metadata[:queue]).to eq('maintenance')
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

    it 'detects a single-quoted runner command (EXTB-12)' do
      # The three command regexes were double-quote-only, so the
      # frozen-string-literal-era idiom yielded command_type :unknown, no job
      # class, and no :job dependency edge.
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          runner 'CleanupJob.perform_later'
        end
      RUBY

      unit = described_class.new.extract_scheduled_job_file(path, :whenever).first

      expect(unit.metadata[:command_type]).to eq(:runner)
      expect(unit.metadata[:job_class]).to eq('CleanupJob')
      expect(unit.dependencies).to include(hash_including(type: :job, target: 'CleanupJob'))
    end

    it 'detects a single-quoted rake command (EXTB-12)' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          rake 'db:cleanup'
        end
      RUBY

      unit = described_class.new.extract_scheduled_job_file(path, :whenever).first

      expect(unit.metadata[:command_type]).to eq(:rake)
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

    # #204 — the block terminator matched the substring "end" inside
    # identifiers (CalendarSyncJob, WeekendDigest), truncating the body so
    # command detection failed: :unknown command_type, no job_class, no edge.
    it 'parses a runner whose job class contains "end" in its name' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.day do
          runner "CalendarSyncJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(1)

      unit = units.first
      expect(unit.metadata[:command_type]).to eq(:runner)
      expect(unit.metadata[:job_class]).to eq('CalendarSyncJob')
      expect(unit.dependencies).to contain_exactly(
        { type: :job, target: 'CalendarSyncJob', via: :scheduled }
      )
    end

    it 'parses multiple blocks with "end" mid-body in job names' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every 1.week do
          runner "WeekendDigestJob.perform_later"
        end

        every 1.day do
          runner "CalendarSyncJob.perform_now"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.size).to eq(2)
      expect(units.map { |u| u.metadata[:job_class] }).to contain_exactly(
        'WeekendDigestJob', 'CalendarSyncJob'
      )
      expect(units.map { |u| u.metadata[:command_type] }).to all(eq(:runner))
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

  # ── Sidekiq periodic (config/initializers/**/*.rb) ─────────────────

  describe 'Sidekiq periodic registrations' do
    before do
      stub_const('Ledger::PurgeWorker', Class.new)
      stub_const('Ledger::RefreshRatesWorker', Class.new)
      stub_const('Shipment::SweepWorker', Class.new)
      stub_const('Ledger::ApplyHolds', Class.new)
    end

    def periodic_initializer(body, path: 'config/initializers/sidekiq.rb')
      create_file(path, <<~RUBY)
        Sidekiq.configure_server do |config|
          config.periodic do |mgr|
        #{body.gsub(/^/, '    ')}
          end
        end
      RUBY
    end

    def periodic_units
      described_class.new.extract_all.select { |u| u.metadata[:schedule_format] == :sidekiq_periodic }
    end

    it 'emits one unit per registration with its cron and job class' do
      periodic_initializer(<<~RUBY)
        mgr.register('0 7 * * *', 'Ledger::PurgeWorker')
        mgr.register("*/10 * * * *", "Ledger::RefreshRatesWorker")
        mgr.register('35 * * * *', 'Shipment::SweepWorker') # trailing comment
        mgr.register('0 3 * * *', 'Ledger::ApplyHolds')
      RUBY

      units = periodic_units
      expect(units.map(&:type)).to all(eq(:scheduled_job))
      expect(units.map { |u| [u.metadata[:cron_expression], u.metadata[:job_class]] }).to eq(
        [['0 7 * * *', 'Ledger::PurgeWorker'], ['*/10 * * * *', 'Ledger::RefreshRatesWorker'],
         ['35 * * * *', 'Shipment::SweepWorker'], ['0 3 * * *', 'Ledger::ApplyHolds']]
      )
      expect(units.map(&:identifier)).to eq(%w[scheduled:ledger/purge_worker scheduled:ledger/refresh_rates_worker
                                               scheduled:shipment/sweep_worker scheduled:ledger/apply_holds])
      expect(units.map(&:file_path)).to all(eq(File.join(tmp_dir, 'config/initializers/sidekiq.rb')))
      expect(units.map { |u| u.metadata[:line] }).to eq([3, 4, 5, 6])
      expect(units.first.namespace).to eq('Ledger')
      expect(units.map { |u| u.metadata[:job_class_resolved] }).to all(be(true))
      expect(logger).not_to have_received(:warn)
    end

    it 'links each registration to its job unit with the scheduled edge' do
      periodic_initializer("mgr.register('0 7 * * *', 'Ledger::PurgeWorker')\n")

      expect(periodic_units.first.dependencies).to eq([{ type: :job, target: 'Ledger::PurgeWorker', via: :scheduled }])
    end

    it 'accepts the job class as a constant' do
      periodic_initializer("mgr.register('* * * * *', ::Ledger::PurgeWorker)\n")

      unit = periodic_units.first
      expect(unit.metadata[:job_class]).to eq('Ledger::PurgeWorker')
      expect(unit.dependencies.first[:target]).to eq('Ledger::PurgeWorker')
    end

    it 'records registration options in metadata' do
      periodic_initializer(<<~RUBY)
        mgr.register('15 */4 * * *', 'Ledger::PurgeWorker', retry: 1, queue: 'low', tz: 'America/Chicago')
      RUBY

      metadata = periodic_units.first.metadata
      expect(metadata[:options]).to eq('retry' => 1, 'queue' => 'low', 'tz' => 'America/Chicago')
      expect(metadata[:queue]).to eq('low')
    end

    it 'humanizes common cron patterns' do
      periodic_initializer(<<~RUBY)
        mgr.register('0 * * * *', 'Ledger::PurgeWorker')
        mgr.register('*/10 * * * *', 'Ledger::RefreshRatesWorker')
      RUBY

      expect(periodic_units.map { |u| u.metadata[:frequency_human_readable] })
        .to eq(['every hour', 'every 10 minutes'])
    end

    it 'describes daily, hourly, and weekly registrations' do
      periodic_initializer(<<~RUBY)
        mgr.register('0 7 * * *', 'Ledger::PurgeWorker')
        mgr.register('35 * * * *', 'Shipment::SweepWorker')
        mgr.register('0 8 * * 0', 'Ledger::ApplyHolds')
      RUBY

      expect(periodic_units.map { |u| u.metadata[:frequency_human_readable] })
        .to eq(['daily at 07:00', 'hourly at :35', 'weekly on Sunday at 08:00'])
    end

    it 'finds registrations nested inside conditionals in the periodic block' do
      periodic_initializer(<<~RUBY)
        if ENV['SCHEDULE_SWEEPS']
          mgr.register('35 * * * *', 'Shipment::SweepWorker')
        end
      RUBY

      expect(periodic_units.map { |u| u.metadata[:job_class] }).to eq(['Shipment::SweepWorker'])
    end

    it 'reads registrations made through a numbered block parameter' do
      create_file('config/initializers/sidekiq.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.periodic do
            _1.register('0 7 * * *', 'Ledger::PurgeWorker')
          end
        end
      RUBY

      expect(periodic_units.map { |u| [u.metadata[:job_class], u.metadata[:line]] })
        .to eq([['Ledger::PurgeWorker', 3]])
    end

    it 'reads registrations made through the it block parameter' do
      create_file('config/initializers/sidekiq.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.periodic { it.register('35 * * * *', Shipment::SweepWorker) }
        end
      RUBY

      expect(periodic_units.map { |u| u.metadata[:job_class] }).to eq(['Shipment::SweepWorker'])
    end

    it 'ignores _1 and it outside the periodic block they belong to' do
      create_file('config/initializers/sidekiq.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.periodic do |mgr|
            [1].each { _1.register('0 7 * * *', 'Ledger::PurgeWorker') }
          end
          config.periodic { [2].each { |n| n.register('0 8 * * *', 'Ledger::RefreshRatesWorker') } }
        end
      RUBY

      expect(periodic_units).to eq([])
    end

    it 'keeps a registration whose cron is not a literal and records its source' do
      periodic_initializer("mgr.register(ENV.fetch('PURGE_CRON'), 'Ledger::PurgeWorker')\n")

      metadata = periodic_units.first.metadata
      expect(metadata).to include(cron_expression: nil, cron_source: "ENV.fetch('PURGE_CRON')",
                                  frequency_human_readable: nil, job_class: 'Ledger::PurgeWorker')
      expect(logger).to have_received(:warn).with(/sidekiq\.rb:3.*cron is not a literal/)
    end

    it 'ignores register calls whose receiver is not the periodic block parameter' do
      create_file('config/initializers/registry.rb', <<~RUBY)
        Widget.registry.register('0 7 * * *', 'Ledger::PurgeWorker')
        Sidekiq.configure_server do |config|
          config.periodic do |mgr|
            other.register('0 7 * * *', 'Ledger::RefreshRatesWorker')
          end
        end
      RUBY

      expect(periodic_units).to eq([])
    end

    it 'scans nested initializer directories, environments, and application.rb' do
      periodic_initializer("mgr.register('0 7 * * *', 'Ledger::PurgeWorker')\n",
                           path: 'config/initializers/jobs/sidekiq.rb')
      periodic_initializer("mgr.register('0 8 * * *', 'Ledger::RefreshRatesWorker')\n",
                           path: 'config/environments/production.rb')
      periodic_initializer("mgr.register('0 9 * * *', 'Shipment::SweepWorker')\n",
                           path: 'config/application.rb')

      expect(periodic_units.map { |u| u.metadata[:job_class] })
        .to contain_exactly('Ledger::PurgeWorker', 'Ledger::RefreshRatesWorker', 'Shipment::SweepWorker')
    end

    it 'skips parsing an initializer that never mentions periodic' do
      create_file('config/initializers/widgets.rb', "Widget.configure { |c| c.size = 3 }\n")
      expect(Prism).not_to receive(:parse)

      expect(described_class.new.extract_all).to eq([])
    end

    it 'warns about an unresolvable job class and still emits the registration' do
      periodic_initializer("mgr.register('0 7 * * *', 'Ledger::MissingWorker')\n")

      units = periodic_units
      expect(logger).to have_received(:warn).with(/Ledger::MissingWorker/)
      expect(units.map { |u| u.metadata[:job_class] }).to eq(['Ledger::MissingWorker'])
      expect(units.first.metadata[:job_class_resolved]).to be(false)
    end

    it 'warns about and skips a registration whose job class is not a literal name' do
      periodic_initializer("mgr.register('0 7 * * *', worker_name)\n")

      expect(periodic_units).to eq([])
      expect(logger).to have_received(:warn).with(/sidekiq\.rb:3.*not a literal name/)
    end

    it 'numbers repeat registrations of one job class by source position' do
      periodic_initializer(<<~RUBY)
        mgr.register('0 7 * * *', 'Ledger::PurgeWorker')
        mgr.register('0 19 * * *', 'Ledger::PurgeWorker')
      RUBY

      expect(periodic_units.map { |u| [u.identifier, u.metadata[:cron_expression]] }).to eq(
        [['scheduled:ledger/purge_worker', '0 7 * * *'], ['scheduled:ledger/purge_worker:2', '0 19 * * *']]
      )
    end

    it 'numbers repeats the same way when file enumeration order changes' do
      periodic_initializer("mgr.register('0 7 * * *', 'Ledger::PurgeWorker')\n", path: 'config/initializers/a.rb')
      periodic_initializer("mgr.register('0 9 * * *', 'Ledger::PurgeWorker')\n", path: 'config/initializers/b.rb')
      extractor = described_class.new
      expected = extractor.extract_all.to_h { |u| [u.identifier, u.metadata[:cron_expression]] }
      files = extractor.instance_variable_get(:@schedule_files)
      extractor.instance_variable_set(:@schedule_files, files.to_a.reverse.to_h)

      expect(extractor.extract_all.to_h { |u| [u.identifier, u.metadata[:cron_expression]] }).to eq(expected)
      expect(expected).to eq('scheduled:ledger/purge_worker' => '0 7 * * *',
                             'scheduled:ledger/purge_worker:2' => '0 9 * * *')
    end

    it 'qualifies a name shared with another format like any cross-format collision' do
      periodic_initializer("mgr.register('0 7 * * *', 'Ledger::PurgeWorker')\n")
      create_file('config/sidekiq_cron.yml', "ledger/purge_worker:\n  class: OtherJob\n  cron: '0 * * * *'\n")

      expect(described_class.new.extract_all.map(&:identifier))
        .to contain_exactly('scheduled:sidekiq_periodic:ledger/purge_worker',
                            'scheduled:sidekiq_cron:ledger/purge_worker')
    end

    it 'logs and skips an initializer that does not parse' do
      create_file('config/initializers/broken.rb', "config.periodic do |mgr|\n  mgr.register('0 7 * * *',\n")

      expect(described_class.new.extract_all).to eq([])
      expect(logger).to have_received(:error).with(/broken\.rb/)
    end
  end

  # ── Sidekiq-Cron Ruby registrations (config/initializers/**/*.rb) ──

  describe 'Sidekiq-Cron Ruby registrations' do
    before do
      stub_const('Ledger::PurgeWorker', Class.new)
      stub_const('Shipment::SweepWorker', Class.new)
    end

    def cron_ruby_units
      described_class.new.extract_all.select { |u| u.metadata[:schedule_format] == :sidekiq_cron_ruby }
    end

    def sole_cron_ruby_unit
      units = cron_ruby_units
      expect(units.size).to eq(1)
      units.first
    end

    it 'reads Sidekiq::Cron::Job.create with keyword options' do
      path = create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.on(:startup) do
            Sidekiq::Cron::Job.create(name: 'ledger purge', cron: '0 7 * * *', class: 'Ledger::PurgeWorker',
                                      queue: 'low', args: [1, { 'full' => true }])
          end
        end
      RUBY

      unit = sole_cron_ruby_unit
      expect(unit.identifier).to eq('scheduled:ledger purge')
      expect(unit.file_path).to eq(path)
      expect(unit.namespace).to eq('Ledger')
      expect(unit.metadata).to include(
        task_name: 'ledger purge', job_class: 'Ledger::PurgeWorker', job_class_resolved: true,
        cron_expression: '0 7 * * *', queue: 'low', args: [1, { 'full' => true }], line: 3,
        registration: :create, frequency_human_readable: 'daily at 07:00'
      )
      expect(unit.dependencies).to eq([{ type: :job, target: 'Ledger::PurgeWorker', via: :scheduled }])
    end

    it 'reads string-keyed hashes and the klass key' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create('name' => 'sweep', 'cron' => '35 * * * *', 'klass' => Shipment::SweepWorker)
      RUBY

      expect(cron_ruby_units.map { |u| [u.identifier, u.metadata[:job_class]] })
        .to eq([['scheduled:sweep', 'Shipment::SweepWorker']])
    end

    it 'reads Sidekiq::Cron::Job.new(...).save, directly or through a local' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.new(name: 'purge', cron: '0 7 * * *', class: 'Ledger::PurgeWorker').save
        job = Sidekiq::Cron::Job.new(name: 'sweep', cron: '35 * * * *', class: 'Shipment::SweepWorker')
        job.save if job.valid?
        unsaved = Sidekiq::Cron::Job.new(name: 'draft', cron: '0 1 * * *', class: 'Ledger::PurgeWorker')
      RUBY

      expect(cron_ruby_units.map { |u| [u.identifier, u.metadata[:registration]] })
        .to eq([['scheduled:purge', :new_save], ['scheduled:sweep', :new_save]])
    end

    it 'reads load_from_hash and load_from_array with literal arguments' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.load_from_hash(
          'purge' => { 'class' => 'Ledger::PurgeWorker', 'cron' => '0 7 * * *' },
          'sweep' => { 'class' => 'Shipment::SweepWorker', 'cron' => '*/5 * * * *', 'queue' => 'sweeps' }
        )
        Sidekiq::Cron::Job.load_from_array!([
          { 'name' => 'nightly purge', 'class' => 'Ledger::PurgeWorker', 'cron' => '0 2 * * *' }
        ])
        Sidekiq::Cron::Job.load_from_hash!(YAML.load_file('config/other_schedule.yml'))
      RUBY

      expect(cron_ruby_units.map { |u| [u.identifier, u.metadata[:cron_expression], u.metadata[:registration]] })
        .to eq([['scheduled:purge', '0 7 * * *', :load_from_hash], ['scheduled:sweep', '*/5 * * * *', :load_from_hash],
                ['scheduled:nightly purge', '0 2 * * *', :load_from_array]])
      expect(cron_ruby_units.find { |u| u.identifier == 'scheduled:sweep' }.metadata[:queue]).to eq('sweeps')
    end

    it 'ignores calls on receivers other than Sidekiq::Cron::Job' do
      create_file('config/initializers/widgets.rb', <<~RUBY)
        Widget::Cron::Job.create(name: 'x', cron: '0 7 * * *', class: 'Ledger::PurgeWorker')
        Job.create(name: 'y', cron: '0 7 * * *', class: 'Ledger::PurgeWorker')
      RUBY

      expect(cron_ruby_units).to eq([])
    end

    it 'records a computed cron and warns' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: 'purge', cron: Ledger.purge_cron, class: 'Ledger::PurgeWorker')
      RUBY

      expect(sole_cron_ruby_unit.metadata)
        .to include(cron_expression: nil, cron_source: 'Ledger.purge_cron', frequency_human_readable: nil)
      expect(logger).to have_received(:warn).with(/sidekiq_cron\.rb:1.*cron is not a literal/)
    end

    it 'keeps a literal-named job whose class is computed, without an edge' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: 'purge', cron: '0 7 * * *', class: worker_class)
      RUBY

      unit = sole_cron_ruby_unit
      expect(unit.metadata).to include(job_class: nil, job_class_source: 'worker_class')
      expect(unit.dependencies).to eq([])
      expect(logger).to have_received(:warn).with(/sidekiq_cron\.rb:1.*job class is not a literal name/)
    end

    it 'names a job with a computed name after its class and records the name source' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: "purge-\#{Rails.env}", cron: '0 7 * * *', class: 'Ledger::PurgeWorker')
      RUBY

      unit = sole_cron_ruby_unit
      expect(unit.identifier).to eq('scheduled:ledger/purge_worker')
      expect(unit.metadata).to include(task_name: 'ledger/purge_worker', name_source: %("purge-\#{Rails.env}"))
    end

    it 'skips and warns about a registration with neither a literal name nor a literal class' do
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: job_name, cron: '0 7 * * *', class: worker_class)
      RUBY

      expect(cron_ruby_units).to eq([])
      expect(logger).to have_received(:warn).with(/sidekiq_cron\.rb:1.*neither a literal name nor a literal class/)
    end

    it 'numbers repeat registrations of one name by source position' do
      create_file('config/environments/production.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: 'purge', cron: '0 7 * * *', class: 'Ledger::PurgeWorker')
      RUBY
      create_file('config/environments/staging.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: 'purge', cron: '0 9 * * *', class: 'Ledger::PurgeWorker')
      RUBY

      expect(cron_ruby_units.to_h { |u| [u.identifier, u.metadata[:cron_expression]] })
        .to eq('scheduled:purge' => '0 7 * * *', 'scheduled:purge:2' => '0 9 * * *')
    end

    it 'qualifies a name shared with the Sidekiq-Cron YAML file' do
      create_file('config/sidekiq_cron.yml', "purge:\n  class: Ledger::PurgeWorker\n  cron: '0 * * * *'\n")
      create_file('config/initializers/sidekiq_cron.rb', <<~RUBY)
        Sidekiq::Cron::Job.create(name: 'purge', cron: '0 7 * * *', class: 'Ledger::PurgeWorker')
      RUBY

      expect(described_class.new.extract_all.map(&:identifier))
        .to contain_exactly('scheduled:sidekiq_cron:purge', 'scheduled:sidekiq_cron_ruby:purge')
    end

    it 'reads periodic and Sidekiq-Cron registrations from one file with one parse' do
      create_file('config/initializers/sidekiq.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.periodic { |mgr| mgr.register('0 7 * * *', 'Ledger::PurgeWorker') }
        end
        Sidekiq::Cron::Job.create(name: 'sweep', cron: '35 * * * *', class: 'Shipment::SweepWorker')
      RUBY
      allow(Prism).to receive(:parse).and_call_original

      formats = described_class.new.extract_all.map { |u| u.metadata[:schedule_format] }
      expect(formats).to contain_exactly(:sidekiq_periodic, :sidekiq_cron_ruby)
      expect(Prism).to have_received(:parse).once
    end
  end

  # ── sidekiq-scheduler Ruby DSL (config/initializers/**/*.rb) ───────

  describe 'sidekiq-scheduler Ruby schedules' do
    before do
      stub_const('Ledger::PurgeWorker', Class.new)
      stub_const('SweepWorker', Class.new)
      stub_const('HeartbeatWorker', Class.new)
    end

    def scheduler_ruby_units
      described_class.new.extract_all.select { |u| u.metadata[:schedule_format] == :sidekiq_scheduler_ruby }
    end

    it 'reads Sidekiq.schedule = with a literal hash of every schedule type' do
      path = create_file('config/initializers/scheduler.rb', <<~RUBY)
        Sidekiq.configure_server do |config|
          config.on(:startup) do
            Sidekiq.schedule = {
              'purge' => { 'cron' => '0 0 7 * * * America/Chicago', 'class' => 'Ledger::PurgeWorker', 'queue' => 'low' },
              'sweep' => { 'every' => ['45m', { 'first_in' => '10s' }], 'class' => 'SweepWorker' },
              'drain' => { 'interval' => '1h', 'class' => 'SweepWorker' },
              'launch' => { 'at' => '3001/01/01', 'class' => 'Ledger::PurgeWorker' },
              'warmup' => { 'in' => '1h', 'class' => 'SweepWorker', 'args' => ['all'] }
            }
            SidekiqScheduler::Scheduler.instance.reload_schedule!
          end
        end
      RUBY

      units = scheduler_ruby_units
      expect(units.map(&:identifier)).to eq(%w[scheduled:purge scheduled:sweep scheduled:drain
                                               scheduled:launch scheduled:warmup])
      expect(units.map { |u| u.metadata.values_at(:schedule_type, :frequency_human_readable) }).to eq(
        [[:cron, 'daily at 07:00 (America/Chicago)'], [:every, 'every 45 minutes'], [:interval, 'every hour'],
         [:at, 'once at 3001/01/01'], [:in, 'once in 1h']]
      )
      expect(units.first.metadata).to include(cron_expression: '0 0 7 * * * America/Chicago', queue: 'low',
                                              job_class: 'Ledger::PurgeWorker', registration: :schedule)
      expect(units[1].metadata).to include(cron_expression: nil, every: ['45m', { 'first_in' => '10s' }])
      expect(units[3].metadata[:at]).to eq('3001/01/01')
      expect(units[4].metadata).to include(in: '1h', args: ['all'])
      expect(units.map(&:file_path)).to all(eq(path))
      expect(units.first.dependencies).to eq([{ type: :job, target: 'Ledger::PurgeWorker', via: :scheduled }])
    end

    it 'reads Sidekiq.set_schedule with a literal hash' do
      create_file('config/initializers/scheduler.rb', <<~RUBY)
        Sidekiq::Scheduler.dynamic = true
        Sidekiq.set_schedule('heartbeat', { 'every' => ['1m'], 'class' => 'HeartbeatWorker' })
        Sidekiq.set_schedule(:sweep, every: '30s', class: SweepWorker)
        Sidekiq.set_schedule('purge', 'cron' => ['0 7 * * *', { 'first_in' => '1m' }], 'class' => 'Ledger::PurgeWorker')
      RUBY

      units = scheduler_ruby_units
      expect(units.map { |u| [u.identifier, u.metadata[:job_class], u.metadata[:frequency_human_readable]] })
        .to eq([['scheduled:heartbeat', 'HeartbeatWorker', 'every minute'],
                ['scheduled:sweep', 'SweepWorker', 'every 30 seconds'],
                ['scheduled:purge', 'Ledger::PurgeWorker', 'daily at 07:00']])
      expect(units.last.metadata).to include(cron_expression: '0 7 * * *',
                                             cron_options: { 'first_in' => '1m' })
      expect(units.map { |u| u.metadata[:registration] }).to all(eq(:set_schedule))
    end

    it 'takes the job name as the class when the class is omitted' do
      create_file('config/initializers/scheduler.rb', <<~RUBY)
        Sidekiq.schedule = { 'SweepWorker' => { 'cron' => '0 */5 * * * *' }, 'nightly' => { 'cron' => '0 2 * * *' } }
      RUBY

      sweep, nightly = scheduler_ruby_units
      expect(sweep.metadata).to include(job_class: 'SweepWorker', job_class_inferred: true,
                                        frequency_human_readable: 'every 5 minutes')
      expect(sweep.dependencies).to eq([{ type: :job, target: 'SweepWorker', via: :scheduled }])
      expect(nightly.metadata).to include(job_class: nil)
      expect(nightly.dependencies).to eq([])
    end

    it 'skips a schedule assigned from a computed value' do
      create_file('config/initializers/scheduler.rb', <<~RUBY)
        Sidekiq.schedule = YAML.load_file(File.expand_path('../scheduler.yml', __dir__))
        Sidekiq.set_schedule('heartbeat', heartbeat_options)
      RUBY

      expect(scheduler_ruby_units).to eq([])
    end

    it 'ignores schedule assignments on other receivers' do
      create_file('config/initializers/widgets.rb', <<~RUBY)
        Widget.schedule = { 'purge' => { 'cron' => '0 7 * * *', 'class' => 'Ledger::PurgeWorker' } }
        Widget.set_schedule('sweep', { 'every' => '1m', 'class' => 'SweepWorker' })
      RUBY

      expect(scheduler_ruby_units).to eq([])
    end

    it 'records a computed cron and warns' do
      create_file('config/initializers/scheduler.rb', <<~RUBY)
        Sidekiq.set_schedule('purge', { 'cron' => ENV['PURGE_CRON'], 'class' => 'Ledger::PurgeWorker' })
      RUBY

      expect(scheduler_ruby_units.first.metadata)
        .to include(schedule_type: :cron, cron_expression: nil, cron_source: "ENV['PURGE_CRON']")
      expect(logger).to have_received(:warn).with(/sidekiq-scheduler entry at .*scheduler\.rb:1.*cron is not a literal/)
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

    it 'describes daily, hourly, and weekly crons in Sidekiq-Cron YAML' do
      path = create_file('config/sidekiq_cron.yml', <<~YAML)
        morning_ledger:
          cron: "0 7 * * *"
          class: LedgerJob
        sweep:
          cron: "35 * * * *"
          class: SweepJob
        digest:
          cron: "0 8 * * 0 America/Chicago"
          class: DigestJob
      YAML

      units = described_class.new.extract_scheduled_job_file(path, :sidekiq_cron)
      expect(units.map { |u| u.metadata[:frequency_human_readable] })
        .to eq(['daily at 07:00', 'hourly at :35', 'weekly on Sunday at 08:00 (America/Chicago)'])
      expect(units.first.metadata[:cron_expression]).to eq('0 7 * * *')
    end

    it 'describes a quoted cron line in a Whenever every block' do
      path = create_file('config/schedule.rb', <<~RUBY)
        every '0 9 * * 1-5' do
          runner "LedgerJob.perform_later"
        end

        every 1.day, at: '4:30 am' do
          runner "ReportJob.perform_later"
        end
      RUBY

      units = described_class.new.extract_scheduled_job_file(path, :whenever)
      expect(units.map { |u| u.metadata[:frequency_human_readable] }).to eq(['weekdays at 09:00', '1.day'])
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
