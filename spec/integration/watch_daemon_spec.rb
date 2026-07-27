# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# End-to-end daemon behaviour against a real booted app (#164, phase 2).
#
# The unit specs drive `Daemon#process` with a stubbed extractor and prove the
# control flow — classification, restart triggers, failure posture, storm
# fallback. This file proves the thing they can't: that a cycle against a real
# Rails app actually produces a correct index, and how long that takes.
#
# The latency numbers it prints are the measured half of #164's success
# criterion 2. They are fixture-app numbers; a large host app is a separate,
# unmet, validation (see docs/INCREMENTAL_EXTRACTION.md).
#
# Tagged :booted_app — excluded from the default `rake spec`.
RSpec.describe 'Watch daemon against a booted app', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @pristine_root = Dir.mktmpdir('woods_watch_pristine')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @pristine_root)
    @app_root = Dir.mktmpdir('woods_watch_app')
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)

    @db_dir = Dir.mktmpdir('woods_watch_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyApplication.initialize!
    end

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.integer :status, default: 0
        t.timestamps
      end
      create_table :comments, force: true do |t|
        t.references :post
        t.text :body
        t.timestamps
      end
    end
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    require 'woods/watch/daemon'
    require 'woods/mcp/server'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false
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

    @index_dir = Dir.mktmpdir('woods_watch_index')
    Woods::Extractor.new(output_dir: @index_dir).extract_all
  end

  after { FileUtils.rm_rf(@index_dir) if @index_dir }

  include IndexComparison

  def write_file(relative, contents)
    path = File.join(@app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    relative
  end

  # A daemon with reloading stubbed out. The dummy app boots with
  # `eager_load = false` but no reloader wired, and reload semantics are not
  # what this file measures — index correctness and latency are.
  def daemon(**overrides)
    Woods::Watch::Daemon.new(
      output_dir: @index_dir,
      root: @app_root,
      reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
      debounce: 0,
      **overrides
    )
  end

  def full_extraction
    dir = Dir.mktmpdir('woods_watch_full')
    (@scratch ||= []) << dir
    Woods::Extractor.new(output_dir: dir).extract_all
    dir
  end

  after { (@scratch || []).each { |dir| FileUtils.rm_rf(dir) } }

  describe 'a single-file cycle' do
    it 'lands the index in exactly the state a full extraction would' do
      write_file('app/services/checkout_service.rb', "class CheckoutService\n  def call = Post.count\nend\n")

      result = daemon.process(['app/services/checkout_service.rb'])

      expect(result[:state]).to eq(:running)
      expect(result[:action]).to eq(:incremental)
      found = differences(@index_dir, full_extraction)
      expect(found).to(be_empty, "daemon cycle diverged:\n  #{found.join("\n  ")}")
    end

    it 'publishes a generation a reader can see' do
      write_file('config/locales/de.yml', "de:\n  hello: Hallo\n")
      instance = daemon

      before = instance.generation.current.number
      instance.process(['config/locales/de.yml'])

      published = Woods::Generation.new(output_dir: @index_dir).current
      expect(published.number).to eq(before + 1)
      expect(published.reason).to eq('incremental')
    end

    # Criterion 2 wants a single-file change reflected in the index within 5s
    # p95. This measures the extraction half of that — the watcher and
    # debounce sit in front of it and are bounded by configuration, not by the
    # app's size.
    it 'completes well inside the latency budget on the fixture app' do
      durations = Array.new(5) do |i|
        write_file("app/services/timed_#{i}_service.rb", "class Timed#{i}Service\n  def call = :ok\nend\n")
        daemon.process(["app/services/timed_#{i}_service.rb"])[:duration_ms]
      end

      p95 = durations.sort[(durations.size * 0.95).ceil - 1]
      RSpec.configuration.reporter.message(
        "[watch] single-file cycle on the fixture app: #{durations.inspect} ms (p95 #{p95} ms)"
      )

      expect(p95).to be < 5_000
    end
  end

  describe 'a storm' do
    it 'falls back to a full extraction and still matches' do
      paths = Array.new(8) do |i|
        write_file("app/services/storm_#{i}_service.rb", "class Storm#{i}Service\n  def call = :ok\nend\n")
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = daemon(full_extraction_threshold: 4).process(paths)
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      RSpec.configuration.reporter.message("[watch] #{paths.size}-file storm → full extraction in #{elapsed} ms")

      expect(result[:action]).to eq(:full)
      expect(differences(@index_dir, full_extraction)).to be_empty
    end
  end

  # #164 success criterion 3: "with a daemon running, no MCP response is ever
  # served from a cache older than the current published generation — verified
  # by a test that extracts, then queries a long-lived server *without* calling
  # reload, and asserts fresh data."
  describe 'the MCP freshness contract' do
    it 'serves fresh data from a long-lived reader with no reload call' do
      require 'woods/mcp/index_reader'
      reader = Woods::MCP::IndexReader.new(@index_dir)

      expect(reader.find_unit('FreshService')).to be_nil

      write_file('app/services/fresh_service.rb', "class FreshService
  def call = :ok
end
")
      daemon.process(['app/services/fresh_service.rb'])

      # No reader.reload! anywhere in this example — that is the point.
      expect(reader.find_unit('FreshService')).not_to be_nil
      expect(reader.loaded_generation).to eq(Woods::Generation.new(output_dir: @index_dir).current.number)
    end

    it 'keeps serving the last good answer when the daemon is degraded' do
      require 'woods/mcp/index_reader'
      reader = Woods::MCP::IndexReader.new(@index_dir)
      expect(reader.find_unit('Post')).not_to be_nil

      failing = instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true)
      allow(failing).to receive(:reload!).and_raise(SyntaxError, 'unexpected end-of-input')
      write_file('app/models/post.rb', "class Post < ApplicationRecord
  # half-edited")
      daemon(reloader: failing).process(['app/models/post.rb'])

      # The index is frozen, not broken — and woods_status says why.
      expect(reader.find_unit('Post')).not_to be_nil
      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: @index_dir)
      expect(status[:watch][:state]).to eq('degraded')
      expect(status[:watch][:reason]).to include('SyntaxError')
    end

    it 'reports the generation an extraction published in woods_status' do
      require 'woods/mcp/server'
      reader = Woods::MCP::IndexReader.new(@index_dir)

      write_file('config/locales/fr.yml', "fr:
  hello: Bonjour
")
      daemon.process(['config/locales/fr.yml'])

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: @index_dir)
      expect(status[:index][:generation]).to eq(Woods::Generation.new(output_dir: @index_dir).current.number)
      expect(status[:index][:generation_reason]).to eq('incremental')
    end
  end

  describe 'degraded operation' do
    it 'leaves the index intact and the generation frozen when a reload fails' do
      write_file('app/services/broken_service.rb', "class BrokenService\n  def call\n") # deliberately unterminated
      failing_reloader = instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true)
      allow(failing_reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end-of-input')
      broken = daemon(reloader: failing_reloader)

      before_generation = broken.generation.current.number
      before_units = unit_snapshot(@index_dir)

      result = broken.process(['app/services/broken_service.rb'])

      expect(result[:state]).to eq(:degraded)
      expect(broken.generation.current.number).to eq(before_generation)
      expect(unit_snapshot(@index_dir)).to eq(before_units)

      status = JSON.parse(File.read(File.join(@index_dir, Woods::Watch::Status::FILENAME)))
      expect(status['state']).to eq('degraded')
      expect(status['reason']).to include('SyntaxError')
    end
  end
end
