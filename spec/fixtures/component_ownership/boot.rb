# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'action_mailer/railtie'
require 'action_cable/engine'
require 'view_component'
require 'view_component/engine'
require 'phlex'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

def write_source(root, relative, source)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source)
  path
end

def assert_fact(checks, name)
  raise name unless yield

  checks << name
end

Dir.mktmpdir('woods_components') do |root|
  Dir.mktmpdir('woods_external_components') do |external|
    checks = []
    write_source(root, 'config/database.yml', JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))
    write_source(root, 'app/controllers/application_controller.rb',
                 'class ApplicationController < ActionController::API; end')
    write_source(root, 'config/routes.rb', 'Rails.application.routes.draw {}')
    write_source(root, 'app/components/owned_view.rb', 'class OwnedView < ViewComponent::Base; end')
    phlex_path = write_source(root, 'app/components/owned_phlex.rb', 'class OwnedPhlex < Phlex::HTML; end')
    write_source(root, 'app/channels/owned_channel.rb', 'class OwnedChannel < ActionCable::Channel::Base; end')
    write_source(root, 'app/mailers/application_mailer.rb', <<~CODE)
      class ApplicationMailer < ActionMailer::Base
        default from: -> { raise 'executed default' }
        layout 'mail_layout'
        before_action { raise 'executed callback' }
      end
    CODE
    write_source(root, 'app/mailers/child_mailer.rb',
                 'class ChildMailer < ApplicationMailer; def greeting; raise "sent mail"; end; end')
    direct_path = write_source(root, 'app/mailers/direct_mailer.rb', 'class DirectMailer < ActionMailer::Base; end')
    foreign = write_source(external, 'definitions.rb', <<~CODE)
      class ExternalView < ViewComponent::Base; end
      class ExternalPhlex < Phlex::HTML; end
      class ExternalChannel < ActionCable::Channel::Base; end
      class ExternalMailer < ActionMailer::Base; end
      class ReopenedView < ViewComponent::Base; end
    CODE
    require foreign
    write_source(root, 'app/mailers/vendor_child_mailer.rb', 'class VendorChildMailer < ExternalMailer; end')
    write_source(root, 'config/initializers/reopen_component.rb', <<~CODE)
      class ReopenedView
        def app_extension
          raise 'executed component'
        end
      end
    CODE
    vendor = write_source(root, 'vendor/component.rb', 'class VendorView < ViewComponent::Base; end')
    require vendor
    recurring = write_source(root, 'config/recurring.yml', "cleanup:\n  class: CleanupJob\n  schedule: every day\n")
    write_source(root, 'app/jobs/cleanup_job.rb',
                 'class CleanupJob < ActiveJob::Base; def perform; raise "ran job"; end; end')
    write_source(root, 'app/jobs/other_job.rb', 'class OtherJob < ActiveJob::Base; end')

    app = Class.new(Rails::Application)
    Object.const_set(:ComponentOwnershipApplication, app)
    app.config.root = root
    app.config.api_only = true
    app.config.eager_load = false
    app.config.cache_classes = false
    app.config.secret_key_base = 'component-ownership-test'
    app.config.logger = Logger.new(IO::NULL)
    app.initialize!
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    Rails.application.eager_load!
    Woods.configure do |config|
      config.concurrent_extraction = false
      config.enable_snapshots = false
      config.include_framework_sources = false
    end

    # Produce a baseline carrying dependency-only definitions as older writers did.
    legacy = true
    [[Woods::Extractors::ViewComponentExtractor, :app_component?, ExternalView],
     [Woods::Extractors::PhlexExtractor, :app_component?, ExternalPhlex],
     [Woods::Extractors::ActionCableExtractor, :app_channel?, ExternalChannel]].each do |extractor, predicate, klass|
      compatibility = Module.new do
        private

        define_method(predicate) { |candidate| (legacy && candidate == klass) || super(candidate) }
      end
      extractor.prepend(compatibility)
    end
    output = File.join(root, 'tmp/index')
    Woods::Extractor.new(output_dir: output).extract_all
    reader = Woods::MCP::IndexReader.new(output)
    assert_fact(checks, 'legacy fixture contains external definitions') do
      %w[ExternalView ExternalPhlex ExternalChannel].all? { |identifier| reader.find_unit(identifier) }
    end
    legacy = false
    Woods::Extractor.new(output_dir: output).extract_changed([])
    assert_fact(checks, 'authoritative reconciliation removes only dependency-owned definitions') do
      %w[ExternalView ExternalPhlex ExternalChannel VendorView ExternalMailer].all? do |id|
        reader.find_unit(id).nil?
      end &&
        %w[OwnedView OwnedPhlex OwnedChannel ReopenedView].all? { |id| reader.find_unit(id) }
    end
    assert_fact(checks, 'all application mailer inheritance branches are indexed without execution') do
      %w[ApplicationMailer ChildMailer DirectMailer VendorChildMailer].all? do |id|
        reader.find_unit(id, type: 'mailer')
      end &&
        reader.find_unit('ChildMailer').dig('metadata', 'callbacks').size == 1 &&
        reader.find_unit('ApplicationMailer').dig('metadata', 'layout') == 'mail_layout'
    end
    compare = lambda do |label|
      oracle = Dir.mktmpdir('woods_component_oracle')
      Woods::Extractor.new(output_dir: oracle).extract_all
      differences = IndexComparison.differences(output, oracle)
      raise "#{label}: #{differences.inspect}" unless differences.empty?

      checks << label
    ensure
      FileUtils.rm_rf(oracle) if oracle
    end
    compare.call('ownership full/incremental equivalence')
    write_source(root, 'app/components/owned_phlex.rb', <<~CODE)
      class OwnedPhlex < Phlex::HTML
        def new_method
          raise 'executed component method'
        end
      end
    CODE
    File.write(direct_path, 'class DirectMailer < ActionMailer::Base; def new_action; raise "sent mail"; end; end')
    Rails.application.reloader.reload!
    Woods::Extractor.new(output_dir: output).extract_changed([phlex_path, direct_path])
    compare.call('component and mailer edits full/incremental equivalence')
    Woods::Extractor.new(output_dir: output).refresh(:components, :view_components, :action_cable_channels, :mailers)
    compare.call('component and mailer refresh equivalence')

    cron = write_source(root, 'config/sidekiq_cron.yml',
                        "cleanup:\n  class: OtherJob\n  cron: '0 * * * *'\n  queue: alternate\n  args: [7]\n")
    Woods::Extractor.new(output_dir: output).extract_changed([cron])
    assert_fact(checks, 'conflicting schedules retain jobs and qualified identities') do
      reader.find_unit('scheduled:cleanup').nil? &&
        reader.find_unit('scheduled:solid_queue:cleanup').dig('metadata', 'job_class') == 'CleanupJob' &&
        reader.find_unit('scheduled:sidekiq_cron:cleanup').dig('metadata', 'args') == [7]
    end
    compare.call('schedule collision addition equivalence')
    Woods::Extractor.new(output_dir: output).refresh(:scheduled_jobs)
    compare.call('schedule refresh equivalence')
    File.unlink(cron)
    Woods::Extractor.new(output_dir: output).extract_changed([cron])
    assert_fact(checks, 'collision removal restores legacy identity without stale nodes') do
      reader.find_unit('scheduled:cleanup') && reader.find_unit('scheduled:solid_queue:cleanup').nil? &&
        reader.find_unit('scheduled:sidekiq_cron:cleanup').nil?
    end
    compare.call('schedule collision deletion equivalence')
    marker = File.binread(File.join(output, 'generation.json'))
    File.write(recurring, "1:\n  class: CleanupJob\n  schedule: daily\n'1':\n  class: OtherJob\n  schedule: weekly\n")
    %i[incremental refresh full].each do |operation|
      extractor = Woods::Extractor.new(output_dir: output)
      begin
        case operation
        when :incremental then extractor.extract_changed([recurring])
        when :refresh then extractor.refresh(:scheduled_jobs)
        when :full then extractor.extract_all
        end
        raise "#{operation} accepted an ambiguous schedule"
      rescue Woods::ExtractionError, ArgumentError
        raise "#{operation} changed generation" unless File.binread(File.join(output, 'generation.json')) == marker
      end
    end
    checks << 'ambiguous schedule failure retains prior generation in every mode'
    puts JSON.generate(checks: checks, rails: Rails.version, view_component: ViewComponent::VERSION,
                       phlex: Gem.loaded_specs.fetch('phlex').version.to_s)
  end
end
