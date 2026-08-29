# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# M3: incremental runs must refresh the flow artifact family the same way a
# full extraction does — the re-extracted controllers get their
# metadata[:flow_paths] back, flow_index.json and flows/*.json are
# regenerated for the run's controller delta, and a dedicated
# flow-artifact sweep removes documents nothing references anymore.
#
# These assertions are deliberately independent of the other two files that
# test the flow family: spec/integration/incremental_equivalence_spec.rb
# adds flow-artifact equivalence through IndexComparison, and
# spec/resilience/index_validator_spec.rb owns G-2's validation rules.
# Reverting either of those fixes must not break this file, and reverting
# the M3 fix must not break either of them.
#
# Every example creates its own controller with a name no other example
# uses, because a loaded Ruby class leaks across examples in this process:
# re-opening a class can add methods but never remove them, so each example
# mutates only a controller it created. Fold each created file into the
# pristine tree afterwards so the runtime and the filesystem keep agreeing
# in later examples (the same convention the equivalence harness uses).
#
# Tagged :booted_app — boots its own copy of spec/dummy, so run it in its
# own process (its own CI step) like every :booted_app spec.
RSpec.describe 'Incremental flow artifacts', :booted_app do
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    @pristine_root = Dir.mktmpdir('woods_flow_pristine')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @pristine_root)

    @app_root = Dir.mktmpdir('woods_flow_app')
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)

    @db_dir = Dir.mktmpdir('woods_flow_db')
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

    BootedAppRoot.assert!(@app_root)

    ActiveRecord::Base.establish_connection(:test)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.timestamps
      end
    end
    Rails.application.eager_load!

    require 'woods'
    require 'woods/extractor'
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false
    # M3 is gated on precompute_flows (default false) — the whole family is
    # opt-in, so the defect only fires with the flag on.
    Woods.configuration.precompute_flows = true
  end

  after(:all) do
    Woods.configuration = @original_woods_config if defined?(@original_woods_config)
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)
    FileUtils.rm_rf(@app_root) if @app_root
    FileUtils.rm_rf(@pristine_root) if @pristine_root
    FileUtils.rm_rf(@db_dir) if @db_dir
    ENV.delete('WOODS_DUMMY_DB')
  end

  before do
    FileUtils.rm_rf(Dir[File.join(@app_root, '*')])
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)
    Rails.application.reload_routes!
  end

  after do
    (@scratch_dirs || []).each { |dir| FileUtils.rm_rf(dir) }
    @scratch_dirs = []
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def app_path(relative)
    File.join(@app_root, relative)
  end

  def write_controller(file_base, name, actions)
    methods = actions.map do |action, body|
      <<~METHOD
        def #{action}
          #{body}
        end
      METHOD
    end.join("\n")

    write_file("app/controllers/#{file_base}.rb", <<~RUBY)
      class #{name} < ApplicationController
      #{methods}end
    RUBY
    load app_path("app/controllers/#{file_base}.rb")
  end

  def write_file(relative, contents)
    path = app_path(relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    relative
  end

  def extract_all_to_tmp
    dir = Dir.mktmpdir('woods_flow_full')
    (@scratch_dirs ||= []) << dir
    Woods::Extractor.new(output_dir: dir).extract_all
    dir
  end

  def payload_of(index_dir)
    Woods::Generation.new(output_dir: index_dir).payload_dir.to_s
  end

  def flow_index(index_dir)
    JSON.parse(File.read(File.join(payload_of(index_dir), 'flows', 'flow_index.json')))
  end

  def flow_doc(index_dir, name)
    JSON.parse(File.read(File.join(payload_of(index_dir), 'flows', name)))
  end

  def controller_json(index_dir, identifier)
    candidates = Dir[File.join(payload_of(index_dir), 'controllers',
                               "#{Woods::FilenameUtils.safe_segment(identifier)}_*.json")]
    raise "no unit file for #{identifier}" if candidates.empty?

    JSON.parse(File.read(candidates.first))
  end

  def flow_paths_of(index_dir, identifier)
    controller_json(index_dir, identifier)['metadata']['flow_paths'] || {}
  end

  # Keep the leaked class and the tree in agreement for later examples.
  def fold_into_pristine(relative)
    created = app_path(relative)
    return unless File.exist?(created)

    pristine = File.join(@pristine_root, relative)
    FileUtils.mkdir_p(File.dirname(pristine))
    FileUtils.cp(created, pristine)
  end

  # ── M3 defect 1: annotations ─────────────────────────────────────────────

  it 'refreshes metadata[:flow_paths] on a controller re-extracted incrementally' do
    index_dir = extract_all_to_tmp
    write_controller('widgets_controller', 'WidgetsController',
                     index: '@widgets = Post.recent', show: '@widget = Post.find(params[:id])')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/widgets_controller.rb'])
    expect(flow_paths_of(index_dir, 'WidgetsController').keys).to contain_exactly('index', 'show')

    write_controller('widgets_controller', 'WidgetsController',
                     index: '@widgets = Post.recent',
                     show: '@widget = Post.find(params[:id])',
                     create: '@widget = Post.create(title: params[:title])')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/widgets_controller.rb'])

    # A full run would annotate the re-extracted unit; the incremental one
    # used to hand back a fresh unit with no flow_paths at all.
    expect(flow_paths_of(index_dir, 'WidgetsController').keys)
      .to contain_exactly('index', 'show', 'create')

    fold_into_pristine('app/controllers/widgets_controller.rb')
  end

  # ── M3 defect 2: regenerated flow artifacts ─────────────────────────────

  it 'regenerates flow_index.json and the flow documents for a modified controller' do
    index_dir = extract_all_to_tmp
    write_controller('gadgets_controller', 'GadgetsController', index: '@gadgets = Post.recent')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/gadgets_controller.rb'])
    expect(flow_index(index_dir)).not_to have_key('GadgetsController#edit')

    write_controller('gadgets_controller', 'GadgetsController',
                     index: '@gadgets = Post.recent',
                     show: '@gadget = Post.find(params[:id])',
                     edit: '@gadget = Post.find(params[:id])')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/gadgets_controller.rb'])

    expect(flow_index(index_dir)).to have_key('GadgetsController#edit')
    expect(flow_index(index_dir)['GadgetsController#edit']).to eq('flows/GadgetsController_edit.json')
    expect(flow_doc(index_dir, 'GadgetsController_edit.json')['entry_point']).to eq('GadgetsController#edit')

    fold_into_pristine('app/controllers/gadgets_controller.rb')
  end

  # ── M3 defect 3: the dedicated flow-artifact sweep ──────────────────────

  it 'sweeps flow documents for a controller deleted by the run' do
    index_dir = extract_all_to_tmp
    write_controller('doohickeys_controller', 'DoohickeysController', index: '@d = Post.recent')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/doohickeys_controller.rb'])
    expect(flow_index(index_dir)).to have_key('DoohickeysController#index')
    expect(File).to exist(File.join(payload_of(index_dir), 'flows', 'DoohickeysController_index.json'))

    FileUtils.rm_f(app_path('app/controllers/doohickeys_controller.rb'))
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/doohickeys_controller.rb'])

    expect(flow_index(index_dir).keys.grep(/\ADoohickeysController#/)).to be_empty
    expect(Dir[File.join(payload_of(index_dir), 'flows', 'DoohickeysController_*.json')]).to be_empty
  end

  it 'sweeps flow documents for a controller renamed by the run' do
    index_dir = extract_all_to_tmp
    write_controller('trinkets_controller', 'TrinketsController', index: '@t = Post.recent')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/trinkets_controller.rb'])
    expect(flow_index(index_dir)).to have_key('TrinketsController#index')

    FileUtils.rm_f(app_path('app/controllers/trinkets_controller.rb'))
    write_controller('gizmos_controller', 'GizmosController', index: '@g = Post.recent')

    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/trinkets_controller.rb',
                                      'app/controllers/gizmos_controller.rb'])

    index = flow_index(index_dir)
    expect(index.keys.grep(/\ATrinketsController#/)).to be_empty
    expect(index).to have_key('GizmosController#index')
    expect(flow_doc(index_dir, 'GizmosController_index.json')['entry_point']).to eq('GizmosController#index')
    expect(flow_paths_of(index_dir, 'GizmosController')).to have_key('index')
    expect(Dir[File.join(payload_of(index_dir), 'flows', 'TrinketsController_*.json')]).to be_empty

    fold_into_pristine('app/controllers/gizmos_controller.rb')
  end

  it 'keeps flow_index.json and every document it references while sweeping orphans' do
    index_dir = extract_all_to_tmp
    write_controller('sprockets_controller', 'SprocketsController', index: '@s = Post.recent')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/sprockets_controller.rb'])

    # An unreferenced leftover: exactly what an earlier generation could
    # seed forward into this run's payload.
    FileUtils.cp(File.join(payload_of(index_dir), 'flows', 'SprocketsController_index.json'),
                 File.join(payload_of(index_dir), 'flows', 'Ghost_orphan.json'))

    FileUtils.rm_f(app_path('app/controllers/sprockets_controller.rb'))
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/sprockets_controller.rb'])

    flows_dir = File.join(payload_of(index_dir), 'flows')
    expect(File).to exist(File.join(flows_dir, 'flow_index.json'))
    remaining = Dir[File.join(flows_dir, '*.json')].map { |f| File.basename(f) }
    # flow_index.json and the untouched dummy controller's referenced
    # documents survive; the orphan and every Sprockets document go.
    expect(remaining).to include('flow_index.json')
    expect(remaining.grep(/\APostsController_/)).to eq(remaining.grep(/\APostsController_/).sort)
    expect(remaining.grep(/Ghost_orphan|SprocketsController_/)).to be_empty
    expect(flow_index(index_dir)).to have_key('PostsController#index')
  end

  # ── Full vs incremental flow-artifact equivalence ────────────────────────

  it 'produces flow artifacts equivalent to a full extraction (M3/G-2 coverage)' do
    index_dir = extract_all_to_tmp
    write_controller('flanges_controller', 'FlangesController', index: '@f = Post.recent')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/flanges_controller.rb'])

    write_controller('flanges_controller', 'FlangesController',
                     index: '@f = Post.recent',
                     show: '@flange = Post.find(params[:id])')
    Woods::Extractor.new(output_dir: index_dir)
                    .extract_changed(['app/controllers/flanges_controller.rb'])

    full_dir = extract_all_to_tmp

    incremental_flows = flow_inventory(index_dir)
    full_flows = flow_inventory(full_dir)

    expect(incremental_flows.keys).to eq(full_flows.keys)
    incremental_flows.each do |name, body|
      # flow documents carry a generated_at stamp; the contract is
      # everything else, byte for byte.
      expect(body.except('generated_at')).to eq(full_flows[name].except('generated_at'))
    end
    expect(flow_paths_of(index_dir, 'FlangesController'))
      .to eq(flow_paths_of(full_dir, 'FlangesController'))

    fold_into_pristine('app/controllers/flanges_controller.rb')
  end

  def flow_inventory(index_dir)
    flows_dir = File.join(payload_of(index_dir), 'flows')
    Dir[File.join(flows_dir, '*.json')].to_h do |path|
      [File.basename(path), JSON.parse(File.read(path))]
    end
  end
end
