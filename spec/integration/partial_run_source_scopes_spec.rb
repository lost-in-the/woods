# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# A partial run records a new file in the `whole:` scope of every family whose
# rule matches it (#1124): a targeted refresh re-runs the families that read
# the refreshed family's files, and an incremental run that proves the table
# family's output unchanged records the path without re-running it. The
# freshness verifier then reports no change right after the run, and still
# reports a later edit to the file. Booted copy of spec/dummy.
RSpec.describe 'Partial-run source scopes', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'
    require File.expand_path('../dummy/config/application_config', __dir__)

    @pristine_root = Dir.mktmpdir('woods_scopes_pristine')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @pristine_root)
    @app_root = Dir.mktmpdir('woods_scopes_app')
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)
    @db_dir = Dir.mktmpdir('woods_scopes_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyConfig.apply(WoodsDummyApplication.config, @app_root)
      WoodsDummyApplication.initialize!
    end
    BootedAppRoot.assert!(@app_root)

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:posts, force: true) do |t|
        t.string :title
        t.integer :status, default: 0
        t.timestamps
      end
      create_table(:comments, force: true) do |t|
        t.references :post
        t.text :body
        t.timestamps
      end
    end
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    require 'woods/source_inputs/verifier'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@app_root, @pristine_root, @db_dir].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
  end

  before do
    FileUtils.rm_rf(Dir[File.join(@app_root, '*')])
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)
    @index = Dir.mktmpdir('woods_scopes_index')
  end

  after { FileUtils.rm_rf(@index) }

  def write(relative, source)
    path = File.join(@app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    relative
  end

  def extractor
    Woods::Extractor.new(output_dir: @index)
  end

  # What the freshness verifier says about the published index now.
  def changes
    payload = Woods::Generation.new(output_dir: @index).payload_dir
    manifest = JSON.parse(File.read(payload.join('source_inputs.json'), encoding: 'UTF-8'))
    Woods::SourceInputs::Verifier.new(manifest: manifest, output_dir: @index).call.fetch('changes')
  end

  def no_changes
    { 'added' => [], 'changed' => [], 'removed' => [] }
  end

  def manifest
    payload = Woods::Generation.new(output_dir: @index).payload_dir
    JSON.parse(File.read(payload.join('source_inputs.json'), encoding: 'UTF-8'))
  end

  def family_scopes(relative)
    Woods::SourceInputs::Scopes.new(extra_roots: []).for_path(relative) - ['runtime']
  end

  # An app/ Ruby file is also a runtime input. A partial run in a process whose
  # boot no launcher verified keeps the runtime evidence of its baseline, and
  # says so with the runtime_consumption uncertainty (docs/SOURCE_FRESHNESS.md),
  # so the verifier cannot read current here for that scope alone. Every
  # family scope the rules give the file must record it.
  def expect_recorded_by_every_family(relative)
    published = manifest
    expect(family_scopes(relative) - published.fetch('scopes').select { |_, paths| paths.key?(relative) }.keys)
      .to be_empty
    expect(published.fetch('unverified_scopes')).to include('runtime_consumption')
    found = changes
    expect(found).to include('changed' => [], 'removed' => [])
    expect(found.fetch('added') - [relative]).to be_empty
  end

  # The file's next edit must still be reported.
  def expect_edit_reported(relative)
    File.write(File.join(@app_root, relative), "#{File.read(File.join(@app_root, relative))}# edited\n")
    expect(changes.fetch('changed')).to include(relative)
  end

  it 'reports no change after refresh(:rake_tasks) adds a rake file, and reports its later edit' do
    extractor.extract_all
    task = write('lib/tasks/audit.rake', "namespace :audit do\n  task :run do\n  end\nend\n")

    extractor.refresh(:rake_tasks)

    expect(changes).to eq(no_changes)
    expect_edit_reported(task)
  end

  it 'reports no change after refresh(:factories) adds a factory file, and reports its later edit' do
    extractor.extract_all
    factory = write('spec/factories/posts.rb',
                    "FactoryBot.define do\n  factory :post do\n    title { 'x' }\n  end\nend\n")

    extractor.refresh(:factories)

    expect(changes).to eq(no_changes)
    expect_edit_reported(factory)
  end

  {
    'a PORO' => ['app/models/scope_probe_value.rb', "class ScopeProbeValue\n  def call = :ok\nend\n"],
    'a concern' => ['app/models/concerns/scope_probeable.rb',
                    "module ScopeProbeable\n  extend ActiveSupport::Concern\nend\n"]
  }.each do |shape, (relative, source)|
    it "reports no change after an incremental run adds #{shape} that leaves table ownership alone" do
      extractor.extract_all
      write(relative, source)
      load File.join(@app_root, relative)

      extractor.extract_changed([relative])

      expect_recorded_by_every_family(relative)
      expect_edit_reported(relative)
    ensure
      name = File.basename(relative, '.rb').split('_').map(&:capitalize).join
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  # A model class already defined, and already owning its table, before its
  # file appears: the ownership comparison finds nothing new.
  it 'reports no change after an incremental run adds the file of a model the process already defines' do
    moved = write('app/services/scope_tag.rb', "class ScopeTag < ApplicationRecord\n  self.table_name = 'posts'\nend\n")
    load File.join(@app_root, moved)
    extractor.extract_all
    FileUtils.mv(File.join(@app_root, moved), File.join(@app_root, 'app/models/scope_tag.rb'))

    extractor.extract_changed(['app/models/scope_tag.rb', moved])

    expect_recorded_by_every_family('app/models/scope_tag.rb')
    expect_edit_reported('app/models/scope_tag.rb')
  ensure
    if Object.const_defined?(:ScopeTag, false)
      ScopeTag.abstract_class = true
      Object.send(:remove_const, :ScopeTag)
    end
  end
end
