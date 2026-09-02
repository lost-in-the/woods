# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'

# Differential harness for incremental extraction (#164, phase 0).
#
# The oracle is simple and strict: after any sequence of file
# create/modify/delete/rename operations, an index maintained purely by
# `Extractor#extract_changed` must be *equivalent to a cold full extraction of
# the same tree* — identical unit identifier sets, identical per-unit content,
# identical graph nodes and edges, PageRank recomputed. Anything else is
# incremental drift, and drift compounds: a CI chain that restores the previous
# graph and runs `woods:incremental` per merge propagates a missed unit forward
# run over run instead of having it erased by the next full rebuild.
#
# The app under test is a copy of spec/dummy in a tmpdir, mutated in place.
# Both the maintained index and the comparison full extraction run against the
# same booted process, so the comparison isolates *incremental maintenance*
# from Rails reloading.
#
# SCOPE — file-based and whole-app unit types (services, jobs, concerns, rake
# tasks, i18n, lib, POROs, view templates, migrations, test mappings, routes).
# Class-based types (models, controllers, mailers, components, channels) are
# discovered from live descendants, and a constant outlives its file in a
# process that has not reloaded — so deleting a model file here would make the
# comparison full extraction disagree with the filesystem, not with the
# incremental path. Reload semantics are #164 phase 2; the class-based
# *addition* path is covered by a targeted example below that adds a file and
# loads it, which is what a reloading daemon would do.
#
# Tagged :booted_app — excluded from the default `rake spec`, opted into by
# the CI Rails-version matrix with WOODS_RUN_BOOTED_APP=1.

# How many mutations each randomized sequence applies, and which seeds to
# run. Both are env-tunable so a soak run can go far past the CI budget:
#   WOODS_DIFF_OPS=1000 WOODS_DIFF_SEEDS=1,2,3,4,5 bundle exec rspec ...
DIFF_OPERATION_COUNT = Integer(ENV.fetch('WOODS_DIFF_OPS', '60'))
DIFF_SEEDS = ENV.fetch('WOODS_DIFF_SEEDS', '1,2,3').split(',').map { |seed| Integer(seed) }

# Candidate artifacts, chosen to cover single-unit files, multi-unit files,
# non-Ruby files, and files two extractors both claim.
#
# Each family gets its own name prefix so no two families can ever mint the
# same identifier. Woods keys the dependency graph on the bare identifier,
# so a cross-type clash collapses two units onto one node — a real (and
# pre-existing) limitation, but not one this harness is measuring.
ARTIFACT_TEMPLATES = [
  ->(i) { "app/services/svc_#{i}_service.rb" },
  ->(i) { "app/jobs/jb_#{i}_job.rb" },
  ->(i) { "app/policies/pol_#{i}_policy.rb" },        # two extractors claim this
  ->(i) { "app/decorators/dec_#{i}_decorator.rb" },   # and this
  ->(i) { "app/validators/val_#{i}_validator.rb" },
  ->(i) { "app/managers/mgr_#{i}_manager.rb" },
  ->(i) { "app/models/concerns/cnc_#{i}able.rb" },
  ->(i) { "app/models/pro_#{i}_value.rb" },           # PORO, plus caching scan
  ->(i) { "lib/gen/lb_#{i}.rb" },
  ->(i) { "lib/tasks/rk_#{i}.rake" },                 # multi-unit file
  ->(i) { "config/locales/loc_#{i}.yml" },
  ->(i) { "config/initializers/ini_#{i}.rb" },        # also a middleware trigger
  ->(i) { "app/views/gen/erb_#{i}.html.erb" },
  ->(i) { "spec/models/spc_#{i}_spec.rb" },
  ->(i) { "spec/factories/fac_#{i}.rb" },             # whole-app: factories
  ->(i) { "db/migrate/2024010100000#{i}_mig_#{i}.rb" },
  ->(i) { "db/views/vw_#{i}_v01.sql" },               # whole-app: latest-version-wins
  ->(i) { "db/views/vw_#{i}_v02.sql" },
  # GraphQL: the one divergence class confirmed at scale in review. Its
  # PathDispatcher rule reaches `extract_graphql_file`, which is pure static
  # analysis — so these templates need no graphql-ruby installed, and the
  # extractor's full pass is deliberately ungated for the same reason.
  ->(i) { "app/graphql/types/gqt_#{i}_type.rb" },
  ->(i) { "app/graphql/mutations/gqm_#{i}.rb" },
  ->(i) { "app/graphql/resolvers/gqr_#{i}.rb" }
].freeze

RSpec.describe 'Incremental extraction equivalence', :booted_app do
  # ── Booted app ───────────────────────────────────────────────────────────
  before(:all) do
    require 'rails'
    require 'active_record/railtie'
    require 'action_controller/railtie'
    require 'action_mailer/railtie'
    require 'active_job/railtie'
    require 'logger'

    # @pristine_root is the tree every example is reset to; @app_root is the
    # copy the examples mutate. Without the reset, files one example creates
    # leak into the next and a failure stops being reproducible in isolation.
    @pristine_root = Dir.mktmpdir('woods_diff_pristine')
    FileUtils.cp_r(File.join(File.expand_path('../dummy', __dir__), '.'), @pristine_root)

    @app_root = Dir.mktmpdir('woods_diff_app')
    FileUtils.cp_r(File.join(@pristine_root, '.'), @app_root)

    @db_dir = Dir.mktmpdir('woods_diff_db')
    ENV['WOODS_DUMMY_DB'] = File.join(@db_dir, 'dummy.sqlite3')

    unless defined?(WoodsDummyApplication)
      app_class = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.consider_all_requests_local = true
      end
      Object.const_set(:WoodsDummyApplication, app_class)
      WoodsDummyApplication.config.root = @app_root
      WoodsDummyApplication.config.secret_key_base = 'woods-dummy-secret'
      WoodsDummyApplication.initialize!
    end

    # The guard above shares its constant with the other booted specs, so a
    # mismatch means one of them booted first and this harness would compare two
    # extractions of a tree it never mutates — passing vacuously.
    BootedAppRoot.assert!(@app_root)

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
    @original_woods_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.concurrent_extraction = false
    Woods.configuration.pretty_json = false
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
    # A previous example may have redrawn the route set.
    Rails.application.reload_routes!
  end

  # ── Tree mutation ────────────────────────────────────────────────────────

  def app_path(relative)
    File.join(@app_root, relative)
  end

  def write_file(relative, contents)
    path = app_path(relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    relative
  end

  def delete_file(relative)
    FileUtils.rm_f(app_path(relative))
    relative
  end

  # ── Index comparison ─────────────────────────────────────────────────────
  #
  # {IndexComparison} owns the definition of "the two indexes agree", and
  # documents the only three differences it tolerates.

  include IndexComparison

  # ── Harness driver ───────────────────────────────────────────────────────

  # Run a cold full extraction of the current tree into a throwaway directory.
  # This is the reference the maintained index is measured against.
  def full_extraction
    dir = Dir.mktmpdir('woods_diff_full')
    (@scratch_dirs ||= []) << dir
    Woods::Extractor.new(output_dir: dir).extract_all
    dir
  end

  # Baseline the tree, then apply operations one at a time through
  # extract_changed, asserting equivalence at every quiescent point.
  def run_sequence(operations)
    index_dir = Dir.mktmpdir('woods_diff_incr')
    (@scratch_dirs ||= []) << index_dir
    @retired_paths = []
    Woods::Extractor.new(output_dir: index_dir).extract_all

    operations.each_with_index do |operation, step|
      changed = Array(operation.call)
      Woods::Extractor.new(output_dir: index_dir).extract_changed(changed)

      found = differences(index_dir, full_extraction)
      expect(found).to(
        be_empty,
        "diverged after step #{step + 1} (changed: #{changed.inspect}):\n  #{found.join("\n  ")}"
      )
    end

    index_dir
  end

  after do
    (@scratch_dirs || []).each { |dir| FileUtils.rm_rf(dir) }
    @scratch_dirs = []
  end

  # ── Operation vocabulary ─────────────────────────────────────────────────

  def service_source(name, dependency: nil)
    body = dependency ? "    #{dependency}.new.call\n" : "    :ok\n"
    "class #{name}\n  def call\n#{body}  end\nend\n"
  end

  def rake_source(namespace, tasks)
    bodies = tasks.map { |t| "  desc '#{t}'\n  task :#{t} do\n    puts '#{t}'\n  end\n" }.join
    "namespace :#{namespace} do\n#{bodies}end\n"
  end

  # ── Individual gap regressions ───────────────────────────────────────────

  describe 'gap 1 — files the index has never seen' do
    it 'indexes a service created after the baseline extraction' do
      run_sequence([-> { write_file('app/services/checkout_service.rb', service_source('CheckoutService')) }])
    end

    it 'indexes a lib file, an i18n file, and a rake file created after the baseline' do
      run_sequence([
                     lambda {
                       write_file('lib/reporting/csv_writer.rb', "module Reporting\n  class CsvWriter\n  end\nend\n")
                     },
                     -> { write_file('config/locales/de.yml', "de:\n  hello: Hallo\n") },
                     -> { write_file('lib/tasks/reports.rake', rake_source('reports', %w[daily weekly])) }
                   ])
    end

    it 'indexes a nested concern created after the baseline' do
      run_sequence([
                     lambda {
                       write_file('app/models/concerns/auditable.rb',
                                  "module Auditable\n  extend ActiveSupport::Concern\nend\n")
                     }
                   ])
    end
  end

  describe 'gap 2 — deleted files' do
    it 'prunes a service that was deleted' do
      write_file('app/services/temp_service.rb', service_source('TempService'))

      run_sequence([-> { delete_file('app/services/temp_service.rb') }])
    end

    it 'prunes a deleted file even when the caller forgets to list it' do
      write_file('app/services/forgotten_service.rb', service_source('ForgottenService'))

      # The change set names an unrelated file: the deletion sweep is what has
      # to notice, not the caller.
      run_sequence([
                     lambda {
                       delete_file('app/services/forgotten_service.rb')
                       write_file('app/services/other_service.rb', service_source('OtherService'))
                     }
                   ])
    end

    # B-070: `convention_path_unit?` was widened to spare GraphQL units from the
    # sweep, because a *runtime*-defined type records an app/graphql convention
    # path it does not own. But it keyed on unit *type*, so units the static file
    # pass produced — whose path is a real file it was read from — were spared
    # too, and a deleted app/graphql/**.rb survived an unnamed-path sweep
    # forever. The daemon's catch-up is the exposed caller: it runs an empty
    # change set precisely because deletions leave no mtime.
    it 'prunes a deleted graphql type even when the caller forgets to list it' do
      write_file('app/graphql/types/forgotten_type.rb', <<~SRC)
        module Types
          class ForgottenType < Types::BaseObject
            field :id, ID, null: false
          end
        end
      SRC

      run_sequence([
                     lambda {
                       delete_file('app/graphql/types/forgotten_type.rb')
                       write_file('app/services/unrelated_service.rb', service_source('UnrelatedService'))
                     }
                   ])
    end

    it 'treats a rename as a delete plus an add' do
      write_file('app/services/old_name_service.rb', service_source('OldNameService'))

      run_sequence([
                     lambda {
                       delete_file('app/services/old_name_service.rb')
                       write_file('app/services/new_name_service.rb', service_source('NewNameService'))
                       ['app/services/old_name_service.rb', 'app/services/new_name_service.rb']
                     }
                   ])
    end
  end

  describe 'gap 3 — files defining several units' do
    it 'drops only the task removed from a multi-task rake file' do
      write_file('lib/tasks/multi.rake', rake_source('multi', %w[one two three]))

      run_sequence([
                     -> { write_file('lib/tasks/multi.rake', rake_source('multi', %w[one three])) },
                     -> { write_file('lib/tasks/multi.rake', rake_source('multi', %w[one three four])) },
                     -> { delete_file('lib/tasks/multi.rake') }
                   ])
    end
  end

  describe 'gap 4 — whole-app unit types' do
    it 'refreshes routes when config/routes.rb changes' do
      run_sequence([
                     lambda {
                       write_file('config/routes.rb', <<~RUBY)
                         Rails.application.routes.draw do
                           resources :posts
                           resources :comments, only: [:index]
                         end
                       RUBY
                       Rails.application.reload_routes!
                       'config/routes.rb'
                     }
                   ])
    end

    it 'leaves the manifest timestamp alone when a run changes nothing' do
      index_dir = Dir.mktmpdir('woods_diff_noop')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      before = read_json(index_dir, 'manifest.json')['extracted_at']
      sleep 1.1 # the manifest stamp has second resolution
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['README.md'])

      expect(read_json(index_dir, 'manifest.json')['extracted_at']).to eq(before)
    end
  end

  describe 'gap 5 — derived artifacts' do
    it 'recomputes PageRank and graph analysis on an incremental run' do
      index_dir = Dir.mktmpdir('woods_diff_derived')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      before_analysis = analysis_snapshot(index_dir)

      write_file('app/services/hub_service.rb', service_source('HubService'))
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/hub_service.rb'])

      graph = read_json(index_dir, 'dependency_graph.json')
      expect(graph['pagerank']).to include('HubService')

      after_analysis = analysis_snapshot(index_dir)
      expect(after_analysis).not_to eq(before_analysis)
      expect(after_analysis).to eq(analysis_snapshot(full_extraction))
    end
  end

  # ── SUMMARY.md totals (M4) ───────────────────────────────────────────────
  #
  # An incremental run used to ship the seeded previous generation's
  # SUMMARY.md unchanged — write_structural_summary returned early on the
  # always-empty @results — so the totals a reader saw went stale the moment
  # the run added or removed units. The summary is now derived from the same
  # persisted type indexes the manifest counts, and the oracle compares the
  # two in every index it sees.
  describe 'SUMMARY.md totals (M4)' do
    def summary_totals(dir)
      content = File.read(File.join(payload_dir(dir), 'SUMMARY.md'))
      content.match(/^Units: (\d+) \| Chunks: (\d+)/).captures.map(&:to_i)
    end

    it 'matches the manifest after an incremental run adds and removes units' do
      index_dir = Dir.mktmpdir('woods_diff_summary')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      write_file('app/services/summary_service.rb', service_source('SummaryService'))
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/summary_service.rb'])

      manifest = read_json(index_dir, 'manifest.json')
      units, chunks = summary_totals(index_dir)
      expect(units).to eq(manifest['total_units'])
      expect(chunks).to eq(manifest['total_chunks'])

      delete_file('app/services/summary_service.rb')
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/summary_service.rb'])

      manifest = read_json(index_dir, 'manifest.json')
      units, chunks = summary_totals(index_dir)
      expect(units).to eq(manifest['total_units'])
      expect(chunks).to eq(manifest['total_chunks'])
    end
  end

  describe 'class-based additions' do
    it 'indexes a service class the file dispatcher and the descendant scan both see' do
      # The reconciliation path keys on live descendants, so the class has to
      # be loaded — which is what a reloading daemon would do after the write.
      run_sequence([
                     lambda {
                       write_file('app/models/tag.rb', <<~RUBY)
                         class Tag < ApplicationRecord
                           self.table_name = 'posts'
                         end
                       RUBY
                       load app_path('app/models/tag.rb')
                       'app/models/tag.rb'
                     }
                   ])
    end

    # `Tag` stays in ActiveRecord::Base.descendants for the rest of the
    # process — there is no unload without a Rails reload, which is #164
    # phase 2. Fold the file into the pristine tree so the runtime and the
    # filesystem keep agreeing in every later example.
    after do
      FileUtils.cp(app_path('app/models/tag.rb'), File.join(@pristine_root, 'app/models/tag.rb'))
    end
  end

  describe 'class-discovered job nested in a model file (N-1)' do
    # spec/dummy/app/models/billing/invoicing/reconciler.rb nests
    # `RefreshJob < ApplicationJob` inside a compact-form PORO. The full path
    # finds the job by descendant walk with the model file as its file_path.
    # The incremental path used to re-derive it from that file, naming the
    # enclosing class, and registered a duplicate job unit under the PORO's
    # identifier — flipping the node type and adding a false variant.
    def touch_source(relative)
      write_file(relative, "#{File.read(app_path(relative))}# touched\n")
    end

    it 'stays equivalent when the enclosing model file changes' do
      run_sequence([-> { touch_source('app/models/billing/invoicing/reconciler.rb') }])
    end

    it 'stays equivalent when a model the nested job depends on changes' do
      run_sequence([-> { touch_source('app/models/post.rb') }])
    end
  end

  describe 'class-based move-shape (M1)' do
    # A model file moved with its constant unchanged: the first
    # reconciliation pass sees the class as known, the prune removes it for
    # the vanished old path, and the second pass used to refuse to re-add
    # it (`except: pruned`) — one generation served an index with the model
    # missing. The moved file still defines the class, which is what makes
    # a re-add safe: without it (a plain deletion), the constant outlives
    # its file and must stay pruned.
    it 're-adds a model whose file moved across autoload roots with its constant unchanged after ONE run' do
      write_file('app/models/tag.rb', <<~RUBY)
        class Tag < ApplicationRecord
          self.table_name = 'posts'
        end
      RUBY
      load app_path('app/models/tag.rb')

      index_dir = run_sequence([
                                 lambda {
                                   move_file('app/models/tag.rb', 'app/services/tag.rb')
                                   %w[app/models/tag.rb app/services/tag.rb]
                                 }
                               ])

      # Typed identity across the move: the re-added unit stays a model, and
      # the moved file dispatches to the services extractor as its own unit —
      # same identifier, distinct graph nodes.
      index = index_snapshot(index_dir)
      expect(index['models'].map { |e| e['identifier'] }).to include('Tag')
      expect(index['models'].count { |e| e['identifier'] == 'Tag' }).to eq(1)
      expect(index['services'].map { |e| e['identifier'] }).to include('Tag')
    end

    it 'does not resurrect a deleted namespaced model from another namespace\'s added file' do
      index_dir = Dir.mktmpdir('woods_diff_resurrect')
      (@scratch_dirs ||= []) << index_dir
      write_file('app/models/admin/user.rb', <<~RUBY)
        module Admin
          class User < ApplicationRecord
            self.table_name = 'posts'
          end
        end
      RUBY
      load app_path('app/models/admin/user.rb')
      Woods::Extractor.new(output_dir: index_dir).extract_all

      delete_file('app/models/admin/user.rb')
      write_file('app/models/public/user.rb', <<~RUBY)
        module Public
          class User < ApplicationRecord
            self.table_name = 'posts'
          end
        end
      RUBY
      load app_path('app/models/public/user.rb')

      Woods::Extractor.new(output_dir: index_dir).extract_changed(
        %w[app/models/admin/user.rb app/models/public/user.rb]
      )

      # Deletion without a reload cannot be compared against an in-process
      # full extraction (the deleted constant is still a descendant), so
      # this asserts the maintained index directly: Admin::User stays
      # pruned, the added Public::User is indexed.
      identifiers = index_snapshot(index_dir)['models'].map { |e| e['identifier'] }
      expect(identifiers).not_to include('Admin::User')
      expect(identifiers).to include('Public::User')
    end

    it 'does not resurrect a deleted model from a changed file that only mentions it' do
      index_dir = Dir.mktmpdir('woods_diff_mention')
      (@scratch_dirs ||= []) << index_dir
      write_file('app/models/user.rb', <<~RUBY)
        class User < ApplicationRecord
          self.table_name = 'posts'
        end
      RUBY
      load app_path('app/models/user.rb')
      Woods::Extractor.new(output_dir: index_dir).extract_all

      delete_file('app/models/user.rb')
      write_file('app/models/notes.rb', <<~RUBY)
        # class User was removed; see the changelog entry
        class Notes
          REMOVED = 'class User'
        end
      RUBY

      Woods::Extractor.new(output_dir: index_dir).extract_changed(
        %w[app/models/user.rb app/models/notes.rb]
      )

      # The mention file is governed for Notes; loader identity, not a
      # textual class-name match, is what gates the re-add.
      identifiers = index_snapshot(index_dir)['models'].map { |e| e['identifier'] }
      expect(identifiers).not_to include('User')
    end

    # The moved/deleted classes stay in descendants for the rest of the
    # process and resolve to their in-tree files — fold them into the
    # pristine tree so the runtime and the filesystem keep agreeing in
    # every later example.
    after do
      %w[app/services/tag.rb app/models/admin/user.rb app/models/public/user.rb
         app/models/user.rb app/models/notes.rb].each do |relative|
        created = app_path(relative)
        next unless File.exist?(created)

        pristine = File.join(@pristine_root, relative)
        FileUtils.mkdir_p(File.dirname(pristine))
        FileUtils.cp(created, pristine)
      end
    end
  end

  # ── Flow artifacts (M3) ──────────────────────────────────────────────────

  # With precompute_flows on, the flow family — flow_index.json, every flow
  # document, and the annotated controller units — is part of the equivalence
  # contract. IndexComparison excludes flows/ from the unit set and compares
  # it as its own snapshot (modulo the flow documents' generated_at stamp).
  describe 'flow artifacts' do
    around do |example|
      Woods.configuration.precompute_flows = true
      example.run
    ensure
      Woods.configuration.precompute_flows = false
    end

    it 'keeps flow artifacts equivalent to a full extraction as controllers change' do
      run_sequence([
                     lambda {
                       write_file('app/controllers/things_controller.rb', <<~RUBY)
                         class ThingsController < ApplicationController
                           def index
                             @things = Post.recent
                           end
                         end
                       RUBY
                       load app_path('app/controllers/things_controller.rb')
                       'app/controllers/things_controller.rb'
                     },
                     lambda {
                       write_file('app/controllers/things_controller.rb', <<~RUBY)
                         class ThingsController < ApplicationController
                           def index
                             @things = Post.recent
                           end

                           def show
                             @thing = Post.find(params[:id])
                           end
                         end
                       RUBY
                       load app_path('app/controllers/things_controller.rb')
                       'app/controllers/things_controller.rb'
                     }
                   ])
    end

    # ThingsController stays in the controller descendants for the rest of
    # the process and resolves to this file. Fold it into the pristine tree
    # so the runtime and the filesystem keep agreeing in every later
    # example.
    after do
      created = app_path('app/controllers/things_controller.rb')
      FileUtils.cp(created, File.join(@pristine_root, 'app/controllers/things_controller.rb')) if File.exist?(created)
    end
  end

  # ── Targeted refresh (phase 1) ───────────────────────────────────────────

  describe 'Extractor#refresh' do
    it 'brings routes back into agreement with a full extraction' do
      index_dir = Dir.mktmpdir('woods_refresh')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      write_file('config/routes.rb', <<~RUBY)
        Rails.application.routes.draw do
          resources :posts
          resources :comments, only: [:index, :show]
        end
      RUBY
      Rails.application.reload_routes!

      # No change set, no path dispatch — just "routes went stale, fix routes".
      result = Woods::Extractor.new(output_dir: index_dir).refresh(:routes)
      expect(result[:types]).to include(:routes)

      found = differences(index_dir, full_extraction)
      expect(found).to(be_empty, "refresh(:routes) diverged:\n  #{found.join("\n  ")}")
    end

    it 'drops route units the new route set no longer defines' do
      index_dir = Dir.mktmpdir('woods_refresh_shrink')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      before_routes = index_snapshot(index_dir)['routes'].map { |e| e['identifier'] }
      expect(before_routes).to include('GET /posts/:id')

      write_file('config/routes.rb', <<~RUBY)
        Rails.application.routes.draw do
          resources :posts, only: [:index]
        end
      RUBY
      Rails.application.reload_routes!
      Woods::Extractor.new(output_dir: index_dir).refresh(:routes)

      after_routes = index_snapshot(index_dir)['routes'].map { |e| e['identifier'] }
      expect(after_routes).not_to include('GET /posts/:id')
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'refreshes a file-scanning whole-app extractor without a change set' do
      index_dir = Dir.mktmpdir('woods_refresh_factories')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      write_file('spec/factories/posts.rb', <<~RUBY)
        FactoryBot.define do
          factory :post do
            title { 'x' }
          end
        end
      RUBY

      Woods::Extractor.new(output_dir: index_dir).refresh(:factories)

      expect(differences(index_dir, full_extraction)).to be_empty
    end
  end

  # ── Randomized differential run ──────────────────────────────────────────

  # The gap-specific examples above pin known failures; this is the part that
  # finds the unknown ones. Seeds are fixed so a failure is reproducible.
  describe 'randomized operation sequences' do
    DIFF_SEEDS.each do |seed|
      it "stays equivalent to a full extraction over #{DIFF_OPERATION_COUNT} random operations (seed #{seed})" do
        random = Random.new(seed)
        live = []

        operations = Array.new(DIFF_OPERATION_COUNT) do
          -> { random_operation(random, live) }
        end

        run_sequence(operations)
      end
    end
  end

  # One randomized tree mutation. Returns the changed paths to hand to
  # extract_changed — deliberately *only* the paths a git diff would list, so
  # the harness exercises the same input shape the rake task produces.
  # rubocop:disable Metrics/CyclomaticComplexity -- a flat
  # dispatch over the mutation vocabulary; splitting it would hide the shape.
  def random_operation(random, live)
    choice = live.empty? ? :create : %i[create create modify modify delete rename batch][random.rand(7)]

    case choice
    when :create
      relative = random_artifact(random, live)
      live << relative unless live.include?(relative)
      write_artifact(relative, random)
    when :modify
      write_artifact(live[random.rand(live.size)], random)
    when :delete
      delete_file(live.delete_at(random.rand(live.size)))
    when :rename
      rename_operation(random, live)
    when :batch
      # A small storm: several files in one change set, as a rebase or a
      # branch switch would produce.
      Array.new(1 + random.rand(4)) { random_operation(random, live) }.flatten.compact
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  # Two shapes, because they exercise different machinery.
  #
  # The rewrite shape (delete + add with fresh content) matches git's
  # `--no-renames` diff semantics and what a Ruby rename usually means: the
  # constant moves with the file.
  #
  # The *move* shape preserves the bytes — `FileUtils.mv`, which is what an
  # editor rename and `git mv` actually do. Only generating the rewrite shape
  # meant any bug keyed on content-hash caching or identifier-follows-file
  # tracking was invisible to the harness: the content always changed, so a
  # cache that wrongly kept a hit could never be caught.
  def rename_operation(random, live)
    from = live.delete_at(random.rand(live.size))
    to = renamed_path(from, random)
    live << to

    if random.rand(2).zero?
      move_file(from, to)
      # The moved file still defines `from`'s constant. See {#random_artifact}.
      (@retired_paths ||= []) << from
    else
      delete_file(from)
      write_artifact(to, random)
    end

    [from, to]
  end

  def move_file(from, to)
    source = File.join(@app_root, from)
    target = File.join(@app_root, to)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.mv(source, target)
  end

  def renamed_path(relative, random)
    dir = File.dirname(relative)
    base = File.basename(relative)
    File.join(dir, "r#{random.rand(1000)}_#{base}")
  end

  # Pick a path to create, skipping any whose identifier is already spoken for
  # by a file that was *moved* away from it.
  #
  # A content-preserving move carries the constant with the bytes, so
  # `lib/gen/lb_4.rb` moved to `lib/gen/r415_lb_4.rb` leaves a file still
  # defining `Lb4` while `lb_4.rb` itself is free to be created again — and
  # creating it puts two files on one identifier. Full extraction then keeps the
  # first by glob order while an incremental run keeps whichever was written
  # last: B-063, pre-existing, and *not* what this harness measures. The tree is
  # already broken in that state (Ruby would be redefining a constant), so the
  # generator should not produce it. The existing per-family name prefixes guard
  # the cross-type version of this; they cannot see the move-then-recreate one.
  def random_artifact(random, live = [])
    retired = @retired_paths || []
    candidates = ARTIFACT_TEMPLATES.length.times.to_a.shuffle(random: random)

    candidates.each do |slot|
      relative = ARTIFACT_TEMPLATES[slot].call(random.rand(6))
      next if retired.include?(relative) && !live.include?(relative)

      return relative
    end

    ARTIFACT_TEMPLATES[random.rand(ARTIFACT_TEMPLATES.size)].call(random.rand(6))
  end

  # Content is a function of the path's shape plus a nonce, so "modify" is a
  # real content change and each file type exercises its own extractor.
  def write_artifact(relative, random)
    write_file(relative, artifact_source(relative, random.rand(1_000_000), random))
  end

  # rubocop:disable Metrics/CyclomaticComplexity -- a lookup table of file
  # shape to sample content; one branch per extractor under test.
  def artifact_source(relative, nonce, random)
    base = File.basename(relative).sub(/\.\w+(\.\w+)?\z/, '')

    case relative
    when /\.rake\z/ then rake_source(base, Array.new(1 + random.rand(3)) { |n| "task#{n}" })
    when /\.yml\z/ then "en:\n  #{base}: value_#{nonce}\n"
    when /\.sql\z/ then "SELECT #{nonce} AS answer;\n"
    when /\.erb\z/ then "<div><%= Rails.cache.fetch('#{base}_#{nonce}') { 1 } %></div>\n"
    when %r{\Adb/migrate/} then migration_source(base, nonce)
    when %r{\Aspec/factories/} then factory_source(base, nonce)
    when %r{\Aconfig/initializers/} then "# initializer #{nonce}\nRails.application.config.x.#{base} = #{nonce}\n"
    when %r{\Aapp/graphql/} then graphql_source(relative, base, nonce)
    when %r{concerns/} then "module #{camelize(base)}\n  extend ActiveSupport::Concern\n  # #{nonce}\nend\n"
    when /_spec\.rb\z/ then "RSpec.describe Post do\n  it 'x#{nonce}' do\n    expect(Post).to be_a(Class)\n  end\nend\n"
    else "class #{camelize(base)}\n  VERSION = #{nonce}\n  def call\n    Post.count\n  end\nend\n"
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  # Written to match `graphql_class?`'s patterns, which are what the extractor
  # actually keys on — a base-class suffix, not the presence of the gem.
  def graphql_source(relative, base, nonce)
    name = camelize(base)
    case relative
    when %r{/mutations/}
      "module Mutations\n  class #{name} < Mutations::BaseMutation\n    field :ok, Boolean, null: false\n    " \
      "def resolve\n      { ok: #{nonce}.positive? }\n    end\n  end\nend\n"
    when %r{/resolvers/}
      "module Resolvers\n  class #{name} < Resolvers::BaseResolver\n    type [Types::PostType], null: false\n    " \
      "def resolve\n      Post.limit(#{nonce})\n    end\n  end\nend\n"
    else
      "module Types\n  class #{name} < Types::BaseObject\n    field :id, ID, null: false\n    " \
      "field :n#{nonce}, Integer, null: true\n  end\nend\n"
    end
  end

  def factory_source(base, nonce)
    "FactoryBot.define do\n  factory :#{base} do\n    title { 'x#{nonce}' }\n  end\nend\n"
  end

  def migration_source(base, nonce)
    name = camelize(base.sub(/\A\d+_/, ''))
    "class #{name} < ActiveRecord::Migration[7.0]\n  def change\n    # #{nonce}\n  end\nend\n"
  end

  def camelize(base)
    base.split('_').map(&:capitalize).join
  end
end
