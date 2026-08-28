# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'timeout'

# #164 success criterion 4, split honestly between two specs.
#
# The criterion asks for six worktrees with a daemon each, two-plus concurrent
# MCP readers per worktree, and churn everywhere: zero cross-worktree
# contamination, zero deadlocks or orphaned locks, `woods:validate` green in
# every tree.
#
# `Rails.root` is a process singleton, so six *concurrently extracting* booted
# roots cannot exist in one Ruby process — that shape needs six processes, and
# is the part CI does not cover (recorded in docs/WATCH_DAEMON.md). The two
# halves that can be covered are:
#
# * **Here:** six real worktrees, each with a real extraction against its own
#   root and its own index, then concurrent readers across all of them.
#   Proves per-worktree correctness, disjointness, validate-green, and that
#   many readers converge without coordination.
# * **spec/watch/multi_instance_spec.rb:** genuinely concurrent daemon cycles,
#   lock contention, orphaned-lock absence and idle TTL, driven against real
#   files on disk with stubbed extraction. Proves the concurrency properties
#   without needing six booted apps.
#
# Tagged :booted_app — excluded from the default `rake spec`.

WOODS_MW_WORKTREES = 6
WOODS_MW_READERS = 2

RSpec.describe 'Multi-worktree operation', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @canonical = Dir.mktmpdir('woods_mw_canonical')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @canonical)

    @db_dir = Dir.mktmpdir('woods_mw_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @canonical
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyApplication.initialize!
    end

    # Rails applications are singletons and every :booted_app spec shares this
    # constant, so a mismatch means another one booted first and this file is
    # running against its root. Fail loudly rather than quietly testing nothing.
    BootedAppRoot.assert!(@canonical)

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.timestamps
      end
      create_table :comments, force: true do |t|
        t.references :post
        t.timestamps
      end
    end
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    require 'woods/watch/daemon'
    require 'woods/mcp/index_reader'
    require 'woods/resilience/index_validator'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false
  end

  after(:all) do
    Rails.application.config.root = @canonical if defined?(Rails) && @canonical
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    [@canonical, @db_dir].compact.each { |dir| FileUtils.rm_rf(dir) }
    ENV.delete('WOODS_DUMMY_DB')
  end

  # A canonical checkout plus five agent slots, each a copy of the tree with a
  # unit unique to it — the tell for cross-worktree contamination.
  before do
    @slots = Array.new(WOODS_MW_WORKTREES) do |i|
      root = Dir.mktmpdir("woods_mw_slot#{i}")
      FileUtils.cp_r(File.join(@canonical, '.'), root)
      FileUtils.mkdir_p(File.join(root, 'app/services'))
      File.write(File.join(root, 'app/services', "slot_#{i}_service.rb"),
                 "class Slot#{i}Service\n  def call = :ok\nend\n")
      { index: i, root: root, output: Dir.mktmpdir("woods_mw_out#{i}") }
    end
  end

  after do
    Rails.application.config.root = @canonical
    (@slots || []).each { |slot| FileUtils.rm_rf([slot[:root], slot[:output]]) }
  end

  # Point the booted app at one worktree for the duration of a block. This is
  # why the extraction half of this spec is sequential: there is one Rails.root
  # per process, so two worktrees cannot extract at the same time here.
  def in_worktree(slot)
    Rails.application.config.root = slot[:root]
    yield
  ensure
    Rails.application.config.root = @canonical
  end

  def churn(slot, round)
    relative = "app/services/churn_#{slot[:index]}_#{round}_service.rb"
    FileUtils.mkdir_p(File.dirname(File.join(slot[:root], relative)))
    File.write(File.join(slot[:root], relative),
               "class Churn#{slot[:index]}#{round}Service\n  def call = :ok\nend\n")
    relative
  end

  def daemon_for(slot)
    Woods::Watch::Daemon.new(
      output_dir: slot[:output],
      root: slot[:root],
      reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
      debounce: 0
    )
  end

  def identifiers_in(output, type)
    payload_dir = Woods::Generation.new(output_dir: output).payload_dir
    path = File.join(payload_dir, type, '_index.json')
    return [] unless File.exist?(path)

    JSON.parse(File.read(path)).map { |entry| entry['identifier'] }
  end

  it 'keeps six worktrees disjoint, validate-green, and independently versioned' do
    # Every worktree is populated before any is asserted on, so a slot that
    # leaked into a neighbour is caught wherever it landed.
    @slots.each do |slot|
      in_worktree(slot) do
        Woods::Extractor.new(output_dir: slot[:output]).extract_all
        2.times { |round| daemon_for(slot).process([churn(slot, round)]) }
      end
    end

    @slots.each do |slot| # rubocop:disable Style/CombinableLoops
      services = identifiers_in(slot[:output], 'services')

      expect(services).to include("Slot#{slot[:index]}Service")
      # G-1 regression: the copied dummy's wrapper-nested fixtures must
      # resolve to their child constants in every slot, even though the
      # autoloader singleton still reports the canonical boot root. Before
      # the active-root fallback both files derived Domain::Container here
      # and the collision guard aborted the slot's extraction.
      expect(services).to include('Domain::Container::Parser', 'Domain::Container::Renderer')
      (0...WOODS_MW_WORKTREES).reject { |other| other == slot[:index] }.each do |other|
        expect(services).not_to(include("Slot#{other}Service"), 'cross-worktree contamination')
      end
      2.times { |round| expect(services).to include("Churn#{slot[:index]}#{round}Service") }

      expect(File).not_to exist(File.join(slot[:output], "#{Woods::Watch::Daemon::LOCK_NAME}.lock"))

      report = Woods::Resilience::IndexValidator.new(index_dir: slot[:output]).validate
      expect(report[:errors]).to(be_empty, "slot #{slot[:index]} validate: #{report[:errors].inspect}")

      # Each worktree counts its own generations: one full plus two cycles.
      expect(Woods::Generation.new(output_dir: slot[:output]).current.number).to eq(3)
    end
  end

  it 'serves many concurrent readers per worktree without coordination' do
    @slots.each do |slot|
      in_worktree(slot) { Woods::Extractor.new(output_dir: slot[:output]).extract_all }
    end

    readers = @slots.to_h do |slot|
      [slot[:index], Array.new(WOODS_MW_READERS) { Woods::MCP::IndexReader.new(slot[:output]) }]
    end
    readers.each_value { |group| group.each(&:manifest) }

    # Republish every worktree, then hammer every reader concurrently.
    @slots.each do |slot|
      in_worktree(slot) { daemon_for(slot).process([churn(slot, 0)]) }
    end

    errors = []
    error_mutex = Mutex.new
    threads = readers.flat_map do |index, group|
      group.map do |reader|
        Thread.new do
          8.times { reader.list_units(type: 'service') }
        rescue StandardError => e
          error_mutex.synchronize { errors << "reader #{index}: #{e.class}: #{e.message}" }
        end
      end
    end

    threads.each { |thread| expect(thread.join(120)).not_to(be_nil, 'a reader thread hung') }
    expect(errors).to be_empty

    @slots.each do |slot|
      published = Woods::Generation.new(output_dir: slot[:output]).current.number
      readers[slot[:index]].each do |reader|
        reader.manifest
        expect(reader.loaded_generation).to eq(published)
        expect(identifiers_in(slot[:output], 'services')).to include("Churn#{slot[:index]}0Service")
      end
      # G-1 regression: same as the disjointness example — every slot's
      # extraction must publish the wrapper-nested fixtures resolved.
      expect(identifiers_in(slot[:output], 'services'))
        .to include('Domain::Container::Parser', 'Domain::Container::Renderer')
    end
  end

  it 'lets a hook-triggered sync detect a running daemon and stand down' do
    slot = @slots.first
    status = Woods::Watch::Status.new(output_dir: slot[:output])

    # The check `woods:incremental` makes before doing anything.
    status.write(state: :running, generation: 1)
    expect(status.alive?).to be(true)

    status.write(state: :stopped, reason: 'shut down')
    expect(status.alive?).to be(false)
  end
end
