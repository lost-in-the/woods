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
  # Initializers require a new Rails boot and full extraction. Their task
  # equivalence is covered in incremental_runtime_spec, not this live process.
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
    require File.expand_path('../dummy/config/application_config', __dir__)

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
      WoodsDummyConfig.apply(WoodsDummyApplication.config, @app_root)
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

  it 'tracks nested model mixins through body and callback edits' do
    model_path = write_file('app/models/pinned_record.rb', <<~RUBY)
      class PinnedRecord < ApplicationRecord
        self.table_name = 'posts'
      end
    RUBY
    load app_path(model_path)
    mixin_path = 'app/models/pinned_record/pinnable.rb'
    source = <<~RUBY
      module PinnedRecord::Pinnable
        extend ActiveSupport::Concern
        included do
          before_save :set_pin
        end
        def set_pin
          self.title = 'original pin'
        end
      end
    RUBY
    write_file(mixin_path, source)
    load app_path(mixin_path)
    PinnedRecord.include(PinnedRecord::Pinnable)
    # Keep the reflected inclusion in the model source as it would be on disk.
    File.open(app_path(model_path), 'a') { |file| file.puts('PinnedRecord.include(PinnedRecord::Pinnable)') }
    baseline = full_extraction
    unit = Woods::Extractors::ModelExtractor.new.extract_model(PinnedRecord)
    expect(unit.source_code).to include('original pin')
    payload = Woods::Generation.new(output_dir: baseline).payload_dir
    graph = Woods::DependencyGraph.from_h(JSON.parse(File.read(File.join(payload, 'dependency_graph.json'))))
    expect(graph.identifiers_for_path(app_path(mixin_path))).to include('PinnedRecord::Pinnable')

    %w[body callback].each do |change|
      source = source.sub('original pin', 'changed pin') if change == 'body'
      source = source.sub('before_save', 'before_validation') if change == 'callback'
      write_file(mixin_path, source)
      PinnedRecord.reset_callbacks(:save) if change == 'callback'
      # Reopen the same runtime module, as Rails reload would refresh its methods.
      PinnedRecord::Pinnable.remove_instance_variable(:@_included_block)
      load app_path(mixin_path)
      PinnedRecord.class_eval(&PinnedRecord::Pinnable.instance_variable_get(:@_included_block))
      Woods::Extractor.new(output_dir: baseline).extract_changed([mixin_path])
      expect(differences(baseline, full_extraction)).to be_empty
    end

    # Removing the last include changes only the model file. The orphan
    # runtime-only concern must leave discovery even though its file remains.
    PinnedRecord.abstract_class = true
    Object.send(:remove_const, :PinnedRecord)
    model_source = File.read(app_path(model_path)).sub("PinnedRecord.include(PinnedRecord::Pinnable)\n", '')
    write_file(model_path, model_source)
    load app_path(model_path)
    Woods::Extractor.new(output_dir: baseline).extract_changed([model_path])
    expect(differences(baseline, full_extraction)).to be_empty

    # Adding an include likewise discovers the untouched mixin source.
    load app_path(mixin_path)
    PinnedRecord.include(PinnedRecord::Pinnable)
    write_file(model_path, "#{model_source}PinnedRecord.include(PinnedRecord::Pinnable)\n")
    Woods::Extractor.new(output_dir: baseline).extract_changed([model_path])
    expect(differences(baseline, full_extraction)).to be_empty
  ensure
    if Object.const_defined?(:PinnedRecord)
      PinnedRecord.abstract_class = true
      Object.send(:remove_const, :PinnedRecord)
    end
  end

  it 'refreshes every includer when runtime mixins share a source file' do
    mixin_path = 'app/models/shared_runtime_mixins.rb'
    source = <<~RUBY
      module SharedRuntimeMixins
        module First
          def audit_value
            'original first'
          end
        end
        module Second
          def audit_value
            'original second'
          end
        end
      end
    RUBY
    write_file(mixin_path, source)
    load app_path(mixin_path)
    %w[First Second].each do |name|
      path = write_file("app/models/#{name.downcase}_audit_record.rb", <<~RUBY)
        class #{name}AuditRecord < ApplicationRecord
          self.table_name = 'posts'
          include SharedRuntimeMixins::#{name}
        end
      RUBY
      load app_path(path)
    end
    baseline = full_extraction
    payload = Woods::Generation.new(output_dir: baseline).payload_dir
    graph = Woods::DependencyGraph.from_h(JSON.parse(File.read(File.join(payload, 'dependency_graph.json'))))
    expect(graph.identifiers_for_path(app_path(mixin_path))).to include(
      'SharedRuntimeMixins::First', 'SharedRuntimeMixins::Second'
    )

    write_file(mixin_path, source.gsub('original', 'changed'))
    load app_path(mixin_path)
    touched = Woods::Extractor.new(output_dir: baseline).extract_changed([mixin_path])
    expect(touched).to include('FirstAuditRecord', 'SecondAuditRecord')
    expect(differences(baseline, full_extraction)).to be_empty
  ensure
    %i[FirstAuditRecord SecondAuditRecord].each do |name|
      next unless Object.const_defined?(name)

      Object.const_get(name).abstract_class = true
      Object.send(:remove_const, name)
    end
    Object.send(:remove_const, :SharedRuntimeMixins) if Object.const_defined?(:SharedRuntimeMixins)
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

  describe 'typed source collision publication (#561)' do
    before do
      @collision_paths = %w[original candidate].map do |name|
        identifier = "Collision#{name.capitalize}"
        path = write_file("app/models/collision_#{name}.rb", <<~RUBY)
          class #{identifier}
            def #{name}_owner_marker; :#{name}; end
          end
        RUBY
        load app_path(path)
        path
      end
    end

    after do
      %i[CollisionOriginal CollisionCandidate].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    # Deliberately faulty producer, independent of any naming/parser defect.
    # Its two source classes remain valid and loadable. Cover the plural file
    # entry point too when installed, so module discovery cannot bypass this
    # invariant test by changing the PORO extractor's return contract.
    def inject_source_identity_collision
      remap = lambda do |result|
        Array(result).compact.each do |unit|
          unit.identifier = 'CollisionOriginal' if unit.identifier == 'CollisionCandidate'
        end
        result
      end
      methods = [:extract_all]
      rule = Woods::PathDispatcher.new.file_rules_for(@collision_paths.last).find { |value| value.extractor_key == :poros }
      methods << rule.method_name
      methods.each do |method|
        consumer = allow_any_instance_of(Woods::Extractors::PoroExtractor)
        consumer.to receive(method).and_wrap_original do |original, *args, **kwargs|
          remap.call(original.call(*args, **kwargs))
        end
      end
    end

    def published_collision_snapshot(index)
      payload = Woods::Generation.new(output_dir: index).payload_dir
      {
        marker: File.binread(File.join(index, 'generation.json')),
        graph: File.binread(payload.join('dependency_graph.json')),
        units: Dir[payload.join('poros/*.json')].to_h { |path| [File.basename(path), File.binread(path)] }
      }
    end

    def reader_collision_snapshot(reader)
      {
        original: reader.find_unit('CollisionOriginal', type: 'poro'),
        candidate: reader.find_unit('CollisionCandidate', type: 'poro'),
        graph: JSON.parse(JSON.generate(reader.dependency_graph.to_h))
      }
    end

    %i[full incremental refresh].each do |operation|
      it "refuses #{operation} cross-file identity collisions without replacing the last good reader generation" do
        require 'woods/mcp/index_reader'
        index = full_extraction
        reader = Woods::MCP::IndexReader.new(index)
        published = published_collision_snapshot(index)
        observed = reader_collision_snapshot(reader)
        expect(observed.fetch(:original).fetch('source_code')).to include('original_owner_marker')
        expect(observed.fetch(:candidate).fetch('source_code')).to include('candidate_owner_marker')
        inject_source_identity_collision
        writer = Woods::Extractor.new(output_dir: index)

        attempt = lambda do
          case operation
          when :full then writer.extract_all
          when :incremental then writer.extract_changed([@collision_paths.last])
          when :refresh then writer.refresh(:poros)
          end
        end
        expect(&attempt).to raise_error(Woods::ExtractionError, /same-type identifier collision/) do |error|
          expect(error.message).to include('CollisionOriginal', *@collision_paths)
        end
        expect(published_collision_snapshot(index)).to eq(published)
        expect(reader_collision_snapshot(reader)).to eq(observed)
        # The same held-open reader remains usable; no reconnect hides stale
        # in-memory graph state or an accidentally advanced generation pointer.
        expect(reader.find_unit('CollisionOriginal', type: 'poro').fetch('file_path')).to eq(@collision_paths.first)
      end
    end

    %i[incremental refresh].each do |operation|
      it "accepts an explicit removed-source rename during #{operation}" do
        require 'woods/mcp/index_reader'
        index = full_extraction
        reader = Woods::MCP::IndexReader.new(index)
        before = reader.find_unit('CollisionOriginal', type: 'poro')
        generation = Woods::Generation.new(output_dir: index)
        token = generation.current.token
        from = @collision_paths.first
        to = 'app/models/relocated/collision_original.rb'
        write_file(to, File.read(app_path(from)))
        delete_file(from)
        load app_path(to)
        writer = Woods::Extractor.new(output_dir: index)
        if operation == :incremental
          writer.extract_changed([to, from])
        else
          writer.refresh(:poros)
        end

        expect(generation.current.token).not_to eq(token)
        moved = reader.find_unit('CollisionOriginal', type: 'poro')
        expect(moved.fetch('file_path')).to eq(to)
        expect(moved.fetch('source_code')).to eq(before.fetch('source_code'))
        expect(reader.dependency_graph.node('CollisionOriginal', type: :poro).fetch(:file_path)).to eq(app_path(to))
        expect(reader.dependency_graph.identifiers_for_path(app_path(from))).not_to include('CollisionOriginal')
        expect(differences(index, full_extraction)).to be_empty
      end
    end
  end

  describe 'published source references (#475)' do
    it 'updates unchanged callers on target creation and deletion through one live MCP reader' do
      require 'woods/mcp/server'
      caller_path = write_file('app/models/reference_graph_caller.rb', <<~RUBY)
        class ReferenceGraphCaller
          def execute
            ReferenceGraphTarget.generate
          end
        end
      RUBY
      load app_path(caller_path)
      index = full_extraction
      server = Woods::MCP::Server.build(index_dir: index, response_format: :json, warmup: false)
      lookup = lambda do
        request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                    params: { name: 'lookup', arguments: { identifier: 'ReferenceGraphCaller', type: 'poro' } } }
        JSON.parse(server.handle_json(JSON.generate(request))).fetch('result').fetch('structuredContent').fetch('data')
      end
      before = lookup.call
      expect(before.fetch('dependencies')).not_to include(hash_including('target' => 'ReferenceGraphTarget'))

      target_path = write_file('lib/reference_graph_target.rb', <<~RUBY)
        module ReferenceGraphTarget
          def self.generate
            raise 'reference analysis must never execute this method'
          end
        end
      RUBY
      load app_path(target_path)
      Woods::Extractor.new(output_dir: index).extract_changed([target_path])
      expect(lookup.call.fetch('dependencies')).to include(
        'type' => 'lib', 'target' => 'ReferenceGraphTarget', 'via' => 'code_reference'
      )
      expect(lookup.call.fetch('extracted_at')).to eq(before.fetch('extracted_at'))
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('reverse').fetch('ReferenceGraphTarget')).to include('ReferenceGraphCaller')
      expect(differences(index, full_extraction)).to be_empty

      File.unlink(app_path(target_path))
      Object.send(:remove_const, :ReferenceGraphTarget)
      Woods::Extractor.new(output_dir: index).extract_changed([target_path])
      expect(lookup.call.fetch('dependencies')).not_to include(hash_including('target' => 'ReferenceGraphTarget'))
      expect(read_json(index, 'dependency_graph.json').fetch('reverse').fetch('ReferenceGraphTarget', []))
        .not_to include('ReferenceGraphCaller')
      expect(differences(index, full_extraction)).to be_empty
    ensure
      Object.send(:remove_const, :ReferenceGraphCaller) if Object.const_defined?(:ReferenceGraphCaller, false)
      Object.send(:remove_const, :ReferenceGraphTarget) if Object.const_defined?(:ReferenceGraphTarget, false)
    end

    it 'refreshes source references after a caller edit and retains its last generation after a parse failure' do
      caller_path = write_file('app/models/reference_refresh_caller.rb', <<~RUBY)
        class ReferenceRefreshCaller
          def execute
            ReferenceRefreshFirst.new
          end
        end
      RUBY
      first_path = write_file('lib/reference_refresh_first.rb', 'class ReferenceRefreshFirst; end')
      second_path = write_file('lib/reference_refresh_second.rb', 'class ReferenceRefreshSecond; end')
      [caller_path, first_path, second_path].each { |path| load app_path(path) }
      index = full_extraction
      write_file(caller_path,
                 File.read(app_path(caller_path)).sub('ReferenceRefreshFirst.new', 'ReferenceRefreshSecond.new'))
      load app_path(caller_path)
      Woods::Extractor.new(output_dir: index).refresh(:poros)
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('reverse').fetch('ReferenceRefreshSecond')).to include('ReferenceRefreshCaller')
      expect(graph.fetch('reverse').fetch('ReferenceRefreshFirst', [])).not_to include('ReferenceRefreshCaller')
      expect(differences(index, full_extraction)).to be_empty

      generation = Woods::Generation.new(output_dir: index)
      token = generation.current.token
      cache_path = generation.payload_dir.join('source_references.json')
      cache = File.binread(cache_path)
      write_file(caller_path, 'class ReferenceRefreshCaller; def')
      expect { Woods::Extractor.new(output_dir: index).extract_changed([caller_path]) }
        .to raise_error(Woods::ExtractionError)
      expect(generation.current.token).to eq(token)
      expect(File.binread(cache_path)).to eq(cache)
    ensure
      %i[ReferenceRefreshCaller ReferenceRefreshFirst ReferenceRefreshSecond].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end
  end

  describe 'standalone application modules (#552)' do
    def write_module_bundle
      path = write_file('app/models/ownership_bundle.rb', <<~RUBY)
        class OwnershipBundle
          def value; 'class sibling'; end
        end
        module OwnershipFeature
          def feature_value; OwnershipSibling.value; end
        end
        module OwnershipSibling
          def self.value; raise 'must never execute'; end
        end
      RUBY
      load app_path(path)
      path
    end

    def write_module_includer(include_feature:)
      if Object.const_defined?(:OwnershipRecord, false)
        OwnershipRecord.abstract_class = true
        Object.send(:remove_const, :OwnershipRecord)
      end
      path = write_file('app/models/ownership_record.rb', <<~RUBY)
        class OwnershipRecord < ApplicationRecord
          self.table_name = 'posts'
          #{'include OwnershipFeature' if include_feature}
          def value; OwnershipSibling.value; end
        end
      RUBY
      load app_path(path)
      path
    end

    def expect_module_owner(index, type)
      graph = read_json(index, 'dependency_graph.json')
      types = graph.fetch('type_index')
      expect(types.fetch(type.to_s)).to include('OwnershipFeature')
      other = type == :poro ? 'concern' : 'poro'
      expect(types.fetch(other, [])).not_to include('OwnershipFeature')
      expect(types.fetch('poro')).to include('OwnershipSibling', 'OwnershipBundle')
      expect(graph.dig('reverse', 'OwnershipSibling')).to include('OwnershipFeature', 'OwnershipRecord')
      expect(differences(index, full_extraction)).to be_empty
    end

    after do
      %i[OwnershipRecord OwnershipBundle OwnershipFeature OwnershipSibling OwnershipSecondFeature OwnershipDependency
         ModuleShapes ModuleCaller].each do |name|
        next unless Object.const_defined?(name, false)

        Object.const_get(name).abstract_class = true if name == :OwnershipRecord
        Object.send(:remove_const, name)
      end
    end

    it 'publishes callable module shapes and their typed forward and reverse references' do
      path = write_file('app/models/module_shapes.rb', <<~RUBY)
        module ModuleShapes
          module Singleton
            def self.value; raise 'must never execute'; end
          end
          module Functions
            module_function
            def value; Singleton.value; end
          end
          module Eigenclass
            class << self
              def value; raise 'must never execute'; end
            end
          end
        end
      RUBY
      load app_path(path)
      caller_path = write_file('app/models/module_caller.rb', <<~RUBY)
        class ModuleCaller
          def value
            ModuleShapes::Singleton.value
            ModuleShapes::Functions.value
            ModuleShapes::Eigenclass.value
          end
        end
      RUBY
      load app_path(caller_path)
      index = full_extraction
      snapshot = unit_snapshot(index)
      %w[Singleton Functions Eigenclass].each do |kind|
        identity = "ModuleShapes::#{kind}"
        unit = snapshot.values.find { |value| value['identifier'] == identity }
        expect(unit.fetch('metadata')).to include('ruby_kind' => 'module', 'class_methods' => ['value'])
      end
      graph = read_json(index, 'dependency_graph.json')
      caller = snapshot.values.find { |value| value['identifier'] == 'ModuleCaller' }
      expect(graph.fetch('type_index').fetch('poro')).not_to include('ModuleShapes')
      %w[Singleton Functions Eigenclass].each do |kind|
        identity = "ModuleShapes::#{kind}"
        expect(caller.fetch('dependencies')).to include(
          'type' => 'poro', 'target' => identity, 'via' => 'code_reference'
        )
        expect(graph.fetch('reverse').fetch(identity)).to include('ModuleCaller')
      end
      expect(graph.fetch('reverse').fetch('ModuleShapes::Singleton')).to include('ModuleShapes::Functions')
    end

    it 'migrates ownership on includer-only edits without dropping shared-file siblings' do
      write_module_bundle
      model_path = write_module_includer(include_feature: false)
      index = full_extraction
      expect_module_owner(index, :poro)
      [true, false].each do |included|
        write_module_includer(include_feature: included)
        Woods::Extractor.new(output_dir: index).extract_changed([model_path])
        expect_module_owner(index, included ? :concern : :poro)
      end
    end

    it 'reconciles standalone ownership when only models are refreshed' do
      write_module_bundle
      write_module_includer(include_feature: false)
      index = full_extraction
      [true, false].each do |included|
        write_module_includer(include_feature: included)
        Woods::Extractor.new(output_dir: index).refresh(:models)
        expect_module_owner(index, included ? :concern : :poro)
      end
    end

    it 're-extracts every shared-file owner through transitive source references' do
      dependency_path = write_file('lib/ownership_dependency.rb', 'class OwnershipDependency; end')
      load app_path(dependency_path)
      bundle_path = write_module_bundle
      source = File.read(app_path(bundle_path)).sub('OwnershipSibling.value', 'OwnershipDependency.new')
                   .sub("raise 'must never execute'", 'OwnershipDependency.new')
      source += <<~RUBY
        module OwnershipSecondFeature
          def other_value; OwnershipDependency.new; end
        end
      RUBY
      write_file(bundle_path, source)
      load app_path(bundle_path)
      model_path = write_module_includer(include_feature: true)
      File.open(app_path(model_path), 'a') { |file| file.puts('OwnershipRecord.include(OwnershipSecondFeature)') }
      OwnershipRecord.include(OwnershipSecondFeature)
      index = full_extraction
      write_file(dependency_path, 'class OwnershipDependency; def changed; end; end')
      load app_path(dependency_path)
      # Re-extraction follows both runtime concerns and the standalone sibling
      # back to this shared file, even when the triggering path is elsewhere.
      write_file(bundle_path, "#{source}\n# refreshed through dependency\n")
      touched = Woods::Extractor.new(output_dir: index).extract_changed([dependency_path])
      expect(touched).to include('OwnershipFeature', 'OwnershipSecondFeature', 'OwnershipSibling')
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('type_index').fetch('concern')).to contain_exactly('OwnershipFeature',
                                                                            'OwnershipSecondFeature')
      expect(graph.fetch('type_index').fetch('poro')).to include('OwnershipBundle', 'OwnershipSibling')
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'refuses a transitive shared-file refresh when a partial boot retains an unrefreshed module' do
      dependency_path = write_file('lib/ownership_dependency.rb', 'class OwnershipDependency; end')
      load app_path(dependency_path)
      bundle_path = write_module_bundle
      source = File.read(app_path(bundle_path)).sub('OwnershipSibling.value', 'OwnershipDependency.new')
                   .sub("raise 'must never execute'", 'OwnershipDependency.new')
      write_file(bundle_path, source)
      load app_path(bundle_path)
      index = full_extraction
      generation = Woods::Generation.new(output_dir: index)
      token = generation.current.token
      previous = unit_snapshot(index)
      Object.send(:remove_const, :OwnershipFeature)
      write_file(bundle_path, source.sub('def feature_value;', 'def changed_feature_value;'))
      write_file(dependency_path, 'class OwnershipDependency; def changed; end; end')
      load app_path(dependency_path)
      partial = Woods::Extractor.new(output_dir: index)
      allow(partial).to receive(:safe_eager_load!) { partial.instance_variable_set(:@eager_load_complete, false) }

      # The surviving sibling is genuinely re-extracted through the dependency,
      # while the requested Feature identity remains absent from runtime. A
      # path-level consumption update cannot certify its retained old metadata.
      expect { partial.extract_changed([dependency_path]) }
        .to raise_error(Woods::ExtractionError, /unverified source|retained/)
      expect(generation.current.token).to eq(token)
      expect(unit_snapshot(index)).to eq(previous)
    end

    it 'retains undiscovered modules on partial refresh without certifying changed shared source' do
      bundle_path = write_module_bundle
      write_module_includer(include_feature: false)
      index = full_extraction
      Object.send(:remove_const, :OwnershipFeature)
      partial = Woods::Extractor.new(output_dir: index)
      allow(partial).to receive(:safe_eager_load!) { partial.instance_variable_set(:@eager_load_complete, false) }
      partial.refresh(:poros)
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('type_index').fetch('poro')).to include('OwnershipFeature', 'OwnershipSibling')

      # A newly serialized sibling cannot certify the retained module's old
      # source identity when that same file changes during a partial boot.
      generation = Woods::Generation.new(output_dir: index)
      token = generation.current.token
      write_file(bundle_path, "#{File.read(app_path(bundle_path))}\n# changed sibling source\n")
      retrying = Woods::Extractor.new(output_dir: index)
      allow(retrying).to receive(:safe_eager_load!) { retrying.instance_variable_set(:@eager_load_complete, false) }
      expect { retrying.extract_changed([bundle_path]) }
        .to raise_error(Woods::SourceReferences::RebuildRequired, /incomplete eager loading/)
      expect(generation.current.token).to eq(token)
      expect(read_json(index, 'dependency_graph.json').fetch('type_index').fetch('poro'))
        .to include('OwnershipFeature', 'OwnershipSibling')
    end

    it 'prunes one deleted module from shared source and then the deleted file' do
      bundle_path = write_module_bundle
      write_module_includer(include_feature: false)
      index = full_extraction
      source = File.read(app_path(bundle_path)).sub(/module OwnershipFeature\n.*?^end\n/m, '')
      write_file(bundle_path, source)
      Object.send(:remove_const, :OwnershipFeature)
      load app_path(bundle_path)
      Woods::Extractor.new(output_dir: index).extract_changed([bundle_path])
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('type_index').fetch('poro')).to include('OwnershipBundle', 'OwnershipSibling')
      expect(graph.fetch('type_index').fetch('poro')).not_to include('OwnershipFeature')
      expect(differences(index, full_extraction)).to be_empty

      delete_file(bundle_path)
      %i[OwnershipBundle OwnershipSibling].each { |name| Object.send(:remove_const, name) }
      Woods::Extractor.new(output_dir: index).extract_changed([bundle_path])
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('type_index').fetch('poro', [])).not_to include('OwnershipBundle', 'OwnershipSibling')
      expect(graph.fetch('reverse').fetch('OwnershipSibling', [])).not_to include('OwnershipRecord')
      expect(differences(index, full_extraction)).to be_empty
    end
  end

  # ── Harness driver ───────────────────────────────────────────────────────

  # Run a cold full extraction of the current tree into a throwaway directory.
  # This is the reference the maintained index is measured against.
  def full_extraction
    dir = Dir.mktmpdir('woods_diff_full')
    (@scratch_dirs ||= []) << dir
    Woods::Extractor.new(output_dir: dir).extract_all
    dir
  end

  %i[flat generation].each do |layout|
    it "keeps a legacy #{layout} index readable, refuses partial writes and permits a full rebuild" do
      require 'woods/mcp/index_reader'
      index = full_extraction
      payload = Woods::Generation.new(output_dir: index).payload_dir
      if layout == :flat
        legacy = Dir.mktmpdir('woods_legacy_flat')
        (@scratch_dirs ||= []) << legacy
        FileUtils.cp_r(File.join(payload, '.'), legacy)
        index = legacy
        payload = Pathname.new(index)
      end
      manifest_path = payload.join('manifest.json')
      manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
      manifest['woods_version'] = '1.6.3'
      File.write(manifest_path, JSON.generate(manifest))
      reader = Woods::MCP::IndexReader.new(index)
      expect(reader.find_unit('Post', type: 'model')).not_to be_nil
      original = File.binread(manifest_path)

      expect { Woods::Extractor.new(output_dir: index).extract_changed(['app/models/post.rb']) }
        .to raise_error(Woods::ExtractionError, /woods:extract/)
      expect { Woods::Extractor.new(output_dir: index).refresh(:models) }
        .to raise_error(Woods::ExtractionError, /woods:extract/)
      expect(File.binread(manifest_path)).to eq(original)

      runner = Woods::Extractor.new(output_dir: index)
      runner.extract_all
      runner.raise_on_publication_failure!
      expect(reader.find_unit('Post', type: 'model')).not_to be_nil
      expect(differences(index, full_extraction)).to be_empty
    end
  end

  it 'independently validates full and incremental graph invariants (#413)' do
    require 'woods/resilience/index_validator'
    baseline = full_extraction
    initial = Woods::Resilience::IndexValidator.new(index_dir: baseline).validate
    expect(initial.errors).to be_empty
    changed = write_file('app/services/invariant_service.rb', 'class InvariantService; def call; Post.count; end; end')

    Woods::Extractor.new(output_dir: baseline).extract_changed([changed])
    oracle = full_extraction
    [baseline, oracle].each do |directory|
      report = Woods::Resilience::IndexValidator.new(index_dir: directory).validate
      expect(report.errors).to be_empty
    end
    expect(Woods::Generation.new(output_dir: baseline).current.number).to be >= 2
  end

  it 'publishes owner-specific parent metadata through full, incremental, and MCP lookup (#474)' do
    require 'woods/mcp/server'
    source = <<~RUBY
      class ParentMetadataOwner < Object
        class PlanChange
          class Error < StandardError
          end
        end
      end
    RUBY
    model_path = write_file('app/models/parent_metadata_owner/plan_change.rb', source)
    lib_source = source.sub('ParentMetadataOwner < Object', 'ParentMetadataLibrary')
    lib_path = write_file('lib/parent_metadata_library.rb', lib_source)
    load app_path(model_path)
    load app_path(lib_path)
    expect(ParentMetadataOwner::PlanChange.superclass).to eq(Object)
    expect(ParentMetadataOwner::PlanChange::Error.superclass).to eq(StandardError)
    index = full_extraction

    changed = source.sub('class PlanChange', "class PlanChange\n    def changed; :updated; end")
    write_file(model_path, changed)
    write_file(lib_path, lib_source.sub('class ParentMetadataLibrary',
                                        "class ParentMetadataLibrary\n  def changed; :updated; end"))
    Woods::Extractor.new(output_dir: index).extract_changed([model_path, lib_path])
    oracle = full_extraction
    expect(differences(index, oracle)).to be_empty

    [index, oracle].each do |directory|
      server = Woods::MCP::Server.build(index_dir: directory, response_format: :json, warmup: false)
      { 'ParentMetadataOwner::PlanChange' => 'poro', 'ParentMetadataLibrary' => 'lib' }.each do |identifier, type|
        request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                    params: { name: 'lookup', arguments: { identifier: identifier, type: type } } }
        result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
        expect(result['isError']).to be(false)
        unit = result.fetch('structuredContent').fetch('data')
        expect(unit.fetch('identifier')).to eq(identifier)
        expect(unit.fetch('metadata').fetch('parent_class')).to be_nil
        expect(unit.fetch('source_code')).to include('Parent: none', 'def changed; :updated; end')
      end
    end
  ensure
    Object.send(:remove_const, :ParentMetadataOwner) if Object.const_defined?(:ParentMetadataOwner)
    Object.send(:remove_const, :ParentMetadataLibrary) if Object.const_defined?(:ParentMetadataLibrary)
  end

  it 'publishes GraphQL declaration parents and chunks consistently (#480)' do
    require 'woods/mcp/server'
    source = <<~RUBY
      class ParentGraphql::Item < GraphQL::Schema::Object
        field :id, String, null: false
        class Wrapper < SimpleDelegator
        end
        # #{'padding ' * 1000}
      end
    RUBY
    path = write_file('app/graphql/parent_graphql/item.rb', source)
    index = full_extraction
    write_file(path, source.sub('field :id', 'field :updated_id'))
    Woods::Extractor.new(output_dir: index).extract_changed([path])
    oracle = full_extraction
    expect(differences(index, oracle)).to be_empty

    [index, oracle].each do |directory|
      server = Woods::MCP::Server.build(index_dir: directory, response_format: :json, warmup: false)
      request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                  params: { name: 'lookup', arguments: { identifier: 'ParentGraphql::Item', type: 'graphql_type' } } }
      result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
      expect(result['isError']).to be(false)
      unit = result.fetch('structuredContent').fetch('data')
      expect(unit.fetch('metadata').fetch('parent_class')).to eq('GraphQL::Schema::Object')
      expect(unit.fetch('source_code')).to include('field :updated_id')
      summary = unit.fetch('chunks').find { |chunk| chunk.fetch('chunk_type') == 'summary' }
      expect(summary.fetch('content')).to include("Parent: GraphQL::Schema::Object\n")
    end
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

    it 'indexes a new file passed through a change set with noncanonical paths' do
      baseline = full_extraction
      write_file('app/services/normalized_service.rb', service_source('NormalizedService'))
      changes = Woods::ChangeSet.new(paths: ["#{@app_root}/app//services/./normalized_service.rb"],
                                     root: "#{@app_root}/")

      Woods::Extractor.new(output_dir: baseline).extract_changed(changes.absolute_paths)

      expect(differences(baseline, full_extraction)).to be_empty
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
    %w[primary secondary].each do |removed|
      it "reconciles a task when its #{removed} definition disappears" do
        write_file('lib/tasks/a_shared.rake', rake_source('shared', %w[run]))
        write_file('lib/tasks/z_shared.rake', rake_source('shared', %w[run]))
        baseline = full_extraction
        path = removed == 'primary' ? 'lib/tasks/a_shared.rake' : 'lib/tasks/z_shared.rake'
        delete_file(path)
        Woods::Extractor.new(output_dir: baseline).extract_changed([path])
        expect(differences(baseline, full_extraction)).to be_empty
      end
    end

    it 'reconciles a shared task removed from a surviving secondary file' do
      write_file('lib/tasks/a_shared.rake', rake_source('shared', %w[run]))
      write_file('lib/tasks/z_shared.rake', rake_source('shared', %w[run other]))
      baseline = full_extraction
      path = write_file('lib/tasks/z_shared.rake', rake_source('shared', %w[other]))
      Woods::Extractor.new(output_dir: baseline).extract_changed([path])
      expect(differences(baseline, full_extraction)).to be_empty
    end

    it 'drops only the task removed from a multi-task rake file' do
      write_file('lib/tasks/multi.rake', rake_source('multi', %w[one two three]))

      run_sequence([
                     -> { write_file('lib/tasks/multi.rake', rake_source('multi', %w[one three])) },
                     -> { write_file('lib/tasks/multi.rake', rake_source('multi', %w[one three four])) },
                     -> { delete_file('lib/tasks/multi.rake') }
                   ])
    end
  end

  describe 'volatile dependency per-target limit (B-188)' do
    def git_in_app(*args)
      output, status = Open3.capture2e('git', '-C', @app_root, *args)
      raise "git #{args.first} failed: #{output}" unless status.success?
    end

    it 'persists the cap and full qualifying count across full and incremental extraction with real history' do
      %w[BusyHubService OtherHubService].each do |name|
        write_file("app/services/#{name.underscore}.rb", service_source(name))
      end
      %w[FirstConsumer SecondConsumer ThirdConsumer].each do |name|
        write_file("app/services/#{name.underscore}.rb", service_source(name, dependency: 'BusyHubService'))
      end
      write_file('app/services/other_consumer.rb', service_source('OtherConsumer', dependency: 'OtherHubService'))
      git_in_app('init')
      git_in_app('config', 'user.name', 'Woods test')
      git_in_app('config', 'user.email', 'woods-test@example.invalid')
      git_in_app('add', '.')
      git_in_app('commit', '-m', 'baseline')
      5.times do |i|
        %w[busy_hub_service other_hub_service].each do |name|
          File.open(app_path("app/services/#{name}.rb"), 'a') { |file| file.puts("# change #{i}") }
        end
        git_in_app('commit', '-am', "change hubs #{i}")
      end

      Woods.configuration.volatile_dependency_limit_per_target = 1
      index_dir = full_extraction
      before_report = read_json(index_dir, 'graph_analysis.json')
      expect(before_report.fetch('volatile_dependencies').map { |row| row.fetch('to') })
        .to contain_exactly('BusyHubService', 'OtherHubService')
      expect(before_report.fetch('stats')).to include('volatile_dependency_count' => 4,
                                                      'volatile_dependencies_limit_per_target' => 1,
                                                      'volatile_dependency_reported_count' => 2)

      changed = write_file('app/services/new_consumer.rb', service_source('NewConsumer', dependency: 'BusyHubService'))
      git_in_app('add', changed)
      git_in_app('commit', '-m', 'add consumer')
      Woods::Extractor.new(output_dir: index_dir).extract_changed([changed])

      expect(read_json(index_dir, 'graph_analysis.json').fetch('stats'))
        .to include('volatile_dependency_count' => 5, 'volatile_dependency_reported_count' => 2)
      expect(differences(index_dir, full_extraction)).to be_empty
    ensure
      Woods.configuration.volatile_dependency_limit_per_target = nil
      FileUtils.rm_rf(app_path('.git'))
    end
  end

  describe 'handled source failures' do
    it 'keeps malformed locale batches pending in watch until the repaired batch publishes' do
      require 'woods/watch/daemon'
      path = write_file('config/locales/watch_audit.yml', "en:\n  audit: before\n")
      baseline = full_extraction
      generation = Woods::Generation.new(output_dir: baseline)
      token = generation.current.token
      extractor = Woods::Extractor.new(output_dir: baseline)
      reloader = instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true)
      daemon = Woods::Watch::Daemon.new(output_dir: baseline, root: @app_root,
                                        extractor_factory: -> { extractor }, reloader: reloader,
                                        catch_up: false, debounce: 0)
      write_file(path, "en: [unfinished\n")
      expect(daemon.process([path])[:state]).to eq(:degraded)
      expect(generation.current.token).to eq(token)
      write_file(path, "en:\n  audit: repaired\n")
      expect(daemon.process([])[:state]).to eq(:running)
      expect(generation.current.token).not_to eq(token)
      expect(differences(baseline, full_extraction)).to be_empty
    end

    %w[locale schedule].each do |kind|
      it "preserves the published generation after malformed #{kind} YAML and retries cleanly" do
        path = kind == 'locale' ? 'config/locales/audit.yml' : 'config/sidekiq_cron.yml'
        valid = kind == 'locale' ? "en:\n  audit: before\n" : "audit:\n  cron: '* * * * *'\n  class: AuditJob\n"
        write_file(path, valid)
        baseline = full_extraction
        generation = Woods::Generation.new(output_dir: baseline)
        token = generation.current.token
        published = File.binread(generation.payload_dir.join('dependency_graph.json'))
        expect(JSON.parse(published).fetch('nodes')).to have_key(kind == 'locale' ? 'audit.yml' : 'scheduled:audit')
        extractor = Woods::Extractor.new(output_dir: baseline)
        good_path = write_file('config/locales/healthy.yml', "en:\n  healthy: changed\n")
        write_file(path, "en: [unfinished\n")
        expect { extractor.extract_changed([good_path, path]) }.to raise_error(Woods::ExtractionError)
        expect(generation.current.token).to eq(token)
        expect(File.binread(generation.payload_dir.join('dependency_graph.json'))).to eq(published)
        expect { extractor.extract_changed([path, good_path]) }.to raise_error(Woods::ExtractionError)
        expect(extractor.dependency_graph.node('healthy.yml')).not_to be_nil
        expect(generation.current.token).to eq(token)
        key = kind == 'locale' ? :i18n : :scheduled_jobs
        expect { extractor.refresh(key) }.to raise_error(Woods::ExtractionError)
        expect(generation.current.token).to eq(token)
        write_file(path, valid.sub('before', 'after'))
        extractor.extract_changed([good_path, path])
        expect(differences(baseline, full_extraction)).to be_empty
      end
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

  describe 'package mutations (B-178)' do
    def package_unit(index_dir, type, identifier)
      unit_snapshot(index_dir).values.find do |unit|
        unit['type'] == type && unit['identifier'] == identifier
      end
    end

    def expect_package_membership(index_dir, type, identifier, package)
      unit = package_unit(index_dir, type, identifier)
      expect(unit).not_to be_nil
      node = read_json(index_dir, 'dependency_graph.json').fetch('nodes').fetch(identifier)
      if package
        expect(unit.fetch('metadata')).to include('package' => package)
        expect(node).to include('package' => package)
      else
        expect(unit.fetch('metadata')).not_to have_key('package')
        expect(node).not_to have_key('package')
      end
    end

    def expect_packages(index_dir, names)
      packages = unit_snapshot(index_dir).values.select { |unit| unit['type'] == 'package' }
      expect(packages.map { |unit| unit.fetch('identifier') }).to match_array(names)
      nodes = read_json(index_dir, 'dependency_graph.json').fetch('nodes')
      expect(nodes.select { |_id, node| node['type'] == 'package' }.keys).to match_array(names)
    end

    it 'adds a nested package and reassigns untouched runtime and file-based units' do
      write_file('package.yml', "enforce_dependencies: true\n")
      write_file('app/services/package_service.rb', service_source('PackageService', dependency: 'Post'))
      index_dir = full_extraction
      expect_packages(index_dir, ['.'])
      expect_package_membership(index_dir, 'model', 'Post', '.')
      expect_package_membership(index_dir, 'service', 'PackageService', '.')

      changed = write_file('app/models/package.yml', "dependencies:\n  - .\nenforce_dependencies: true\n")
      Woods::Extractor.new(output_dir: index_dir).extract_changed([changed])

      expect_packages(index_dir, ['.', 'app/models'])
      expect_package_membership(index_dir, 'model', 'Post', 'app/models')
      expect_package_membership(index_dir, 'service', 'PackageService', '.')
      package = package_unit(index_dir, 'package', 'app/models')
      expect(package.fetch('dependencies')).to include(
        include('type' => 'package', 'target' => '.', 'via' => 'package_dependency')
      )
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'removes the last package and clears membership on surviving units and nodes' do
      path = write_file('app/models/package.yml', "enforce_dependencies: true\n")
      index_dir = full_extraction
      expect_packages(index_dir, ['app/models'])
      expect_package_membership(index_dir, 'model', 'Post', 'app/models')

      delete_file(path)
      Woods::Extractor.new(output_dir: index_dir).extract_changed([path])

      expect_packages(index_dir, [])
      expect_package_membership(index_dir, 'model', 'Post', nil)
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'replaces package membership when only packwerk package_paths changes' do
      write_file('app/models/package.yml', "enforce_dependencies: true\n")
      write_file('app/services/package.yml', "enforce_dependencies: true\n")
      write_file('app/services/package_service.rb', service_source('PackageService', dependency: 'Post'))
      config_path = write_file('packwerk.yml', "package_paths:\n  - app/models\n")
      index_dir = full_extraction
      expect_packages(index_dir, ['app/models'])
      expect_package_membership(index_dir, 'model', 'Post', 'app/models')
      expect_package_membership(index_dir, 'service', 'PackageService', nil)

      # Both package files and both source files remain unchanged. Only the
      # configured discovery roots change, so the whole-app trigger must
      # replace packages and re-annotate units absent from the change set.
      extractor = Woods::Extractor.new(output_dir: index_dir)
      %w[app/services app/models].each do |package_path|
        write_file(config_path, "package_paths:\n  - #{package_path}\n")
        extractor.extract_changed([config_path])

        expect_packages(index_dir, [package_path])
        expect_package_membership(index_dir, 'model', 'Post', package_path == 'app/models' ? package_path : nil)
        expect_package_membership(index_dir, 'service', 'PackageService',
                                  package_path == 'app/services' ? package_path : nil)
        expect(differences(index_dir, full_extraction)).to be_empty
      end
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

  # ── graph_sha (B-180) ────────────────────────────────────────────────────
  #
  # `graph_sha` is the digest a consumer caches on: unchanged means "the graph
  # you already processed". It covered `Set#to_a`, so a no-op round trip
  # republished the same graph under a new digest and every such consumer
  # redid its work. {IndexComparison} now compares it in every example; these
  # two state the property directly.
  describe 'graph_sha' do
    def graph_sha(dir)
      read_json(dir, 'graph_analysis.json')['graph_sha']
    end

    it 'returns to its baseline after a create and its delete' do
      index_dir = Dir.mktmpdir('woods_diff_sha')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all
      baseline = graph_sha(index_dir)

      write_file('app/services/round_trip_service.rb', service_source('RoundTripService', dependency: 'Post'))
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/round_trip_service.rb'])
      expect(graph_sha(index_dir)).not_to eq(baseline)

      delete_file('app/services/round_trip_service.rb')
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/round_trip_service.rb'])
      expect(graph_sha(index_dir)).to eq(baseline)
    end

    it 'matches a cold full extraction of the same tree' do
      index_dir = Dir.mktmpdir('woods_diff_sha_full')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      write_file('app/services/matching_service.rb', service_source('MatchingService', dependency: 'Post'))
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/services/matching_service.rb'])

      expect(graph_sha(index_dir)).to eq(graph_sha(full_extraction))
    end
  end

  # ── A capped blast radius ────────────────────────────────────────────────
  #
  # `incremental_blast_radius_depth` stops the re-extraction walk N reverse
  # hops from the changed file. The knob is only usable if the index it
  # maintains is still equivalent to a full extraction: a unit outside the cap
  # keeps content it was never asked to re-derive, and its `dependents` list
  # has to be refreshed by the second pass rather than by a re-extraction.
  #
  # RadiusFar is two hops from the file that changes, so under a cap of 1 it
  # is never re-extracted during the sequence.
  describe 'a capped blast radius' do
    around do |example|
      Woods.configuration.incremental_blast_radius_depth = 1
      example.run
    ensure
      Woods.configuration.incremental_blast_radius_depth = nil
    end

    # Found by identifier rather than by filename: the filename helper lives
    # behind a require this file only performs in its before(:all).
    def unit_json(dir, type, identifier)
      documents = Dir[File.join(payload_dir(dir), type, '*.json')]
                  .reject { |path| File.basename(path) == '_index.json' }
                  .map { |path| JSON.parse(File.read(path)) }
      documents.find { |document| document['identifier'] == identifier }
    end

    def write_radius_chain
      write_leaf('baseline')
      write_file('app/services/radius_near_service.rb',
                 service_source('RadiusNearService', dependency: 'RadiusLeafService'))
      write_file('app/services/radius_far_service.rb',
                 service_source('RadiusFarService', dependency: 'RadiusNearService'))
    end

    def write_leaf(nonce)
      write_file('app/services/radius_leaf_service.rb',
                 "#{service_source('RadiusLeafService')}# #{nonce}\n")
    end

    it 'agrees with a full extraction about a unit two hops out' do
      write_radius_chain

      index_dir = run_sequence([-> { write_leaf('edited') }])

      far = unit_json(index_dir, 'services', 'RadiusFarService')
      expect(far['dependencies'].map { |dep| dep['target'] }).to include('RadiusNearService')
      expect(unit_json(index_dir, 'services', 'RadiusNearService')['dependents'])
        .to eq(unit_json(full_extraction, 'services', 'RadiusNearService')['dependents'])
    end

    it 'refreshes the dependents of a unit two hops out when the edge moves' do
      write_radius_chain

      run_sequence([
                     lambda {
                       # RadiusNear stops pointing at the leaf and points at
                       # RadiusFar instead, so RadiusFar gains a dependent
                       # without ever being re-extracted itself.
                       write_file('app/services/radius_near_service.rb',
                                  service_source('RadiusNearService', dependency: 'RadiusFarService'))
                     }
                   ])
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

  describe 'symbolic external dependency targets' do
    it 'retains untouched HTTP dependents when another service is re-extracted' do
      %w[FirstHttpService SecondHttpService].each do |name|
        write_file("app/services/#{name.underscore}.rb", <<~RUBY)
          class #{name}
            def call
              Net::HTTP.get(URI('https://example.test'))
            end
          end
        RUBY
      end

      index_dir = run_sequence([
                                 lambda {
                                   relative = 'app/services/first_http_service.rb'
                                   write_file(relative, "#{File.read(app_path(relative))}# changed\n")
                                 }
                               ])

      reverse = read_json(index_dir, 'dependency_graph.json').fetch('reverse')
      expect(reverse.fetch('http_api')).to include('FirstHttpService', 'SecondHttpService')
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

  it 'keeps an unrelated locale edit out of hybrid family extraction' do
    path = 'config/locales/hybrid_control.yml'
    index = full_extraction
    write_file(path, "en:\n  hybrid_control: independent edit\n")
    expect_any_instance_of(Woods::Extractors::JobExtractor).not_to receive(:extract_all)
    expect_any_instance_of(Woods::Extractors::SerializerExtractor).not_to receive(:extract_all)

    touched = Woods::Extractor.new(output_dir: index).extract_changed([path])

    expect(touched).not_to be_empty
  end

  it 'publishes behaviorful inline library identities and source references in every extraction mode' do
    require 'woods/mcp/index_reader'
    caller_path = write_file('app/models/inline_library_caller.rb', <<~RUBY)
      class InlineLibraryCaller
        def call; InlineLibrary.perform; end
      end
    RUBY
    path = write_file('lib/extensions/inline_library.rb', 'module InlineLibrary; def self.perform; :full; end; end')
    [caller_path, path].each { |relative| load app_path(relative) }
    expect(Woods::Extractors::LibExtractor.new.send(:managed_constant_path, app_path(path))).to be_nil
    index = full_extraction
    reader = Woods::MCP::IndexReader.new(index)
    writer = Woods::Extractor.new(output_dir: index)

    %i[full incremental refresh].each do |mode|
      unless mode == :full
        write_file(path, "module InlineLibrary; def self.perform; :#{mode}; end; end")
        load app_path(path)
        mode == :incremental ? writer.extract_changed([path]) : writer.refresh(:libs)
        writer.raise_on_publication_failure!
      end
      expect(reader.find_unit('InlineLibrary', type: 'lib').fetch('source_code')).to include(":#{mode}")
      expect(reader.find_unit('Extensions::InlineLibrary', type: 'lib')).to be_nil
      expect(reader.find_unit('InlineLibraryCaller', type: 'poro').fetch('dependencies')).to include(
        'type' => 'lib', 'target' => 'InlineLibrary', 'via' => 'code_reference'
      )
      expect(differences(index, full_extraction)).to be_empty
    end
  ensure
    %i[InlineLibrary InlineLibraryCaller].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
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

  describe 'proven ownership moves out of surviving files (#574)' do
    def ownership_source(split: false)
      nested = split ? '' : 'class Car < OwnershipFleet; end'
      "class OwnershipFleet < ApplicationRecord\n  self.table_name = 'posts'\n  #{nested}\nend\n"
    end

    def prepare_ownership_split
      @ownership_old = write_file('app/models/ownership_fleet.rb', ownership_source)
      @ownership_new = 'app/models/ownership_fleet/car.rb'
      load app_path(@ownership_old)
      full_extraction
    end

    def split_runtime_owner
      # Retire the old class as a Rails reload would; a stale, still-discovered
      # class must not supply evidence that ownership has uniquely moved.
      OwnershipFleet::Car.abstract_class = true
      OwnershipFleet.send(:remove_const, :Car)
      write_file(@ownership_old, ownership_source(split: true))
      write_file(@ownership_new, 'class OwnershipFleet::Car < OwnershipFleet; end')
      load app_path(@ownership_old)
      load app_path(@ownership_new)
    end

    after do
      if Object.const_defined?(:OwnershipFleet, false)
        OwnershipFleet::Car.abstract_class = true if OwnershipFleet.const_defined?(:Car, false)
        OwnershipFleet.abstract_class = true
        Object.send(:remove_const, :OwnershipFleet)
      end
    end

    [false, true].each do |new_first|
      it "keeps a nested STI model split equivalent and stable after another old-file edit, new first=#{new_first}" do
        require 'woods/mcp/index_reader'
        index = prepare_ownership_split
        reader = Woods::MCP::IndexReader.new(index)
        expect(reader.find_unit('OwnershipFleet::Car', type: 'model').fetch('file_path')).to eq(@ownership_old)
        marker = File.binread(File.join(index, 'generation.json'))
        split_runtime_owner
        order = new_first ? [@ownership_new, @ownership_old] : [@ownership_old, @ownership_new]

        touched = Woods::Extractor.new(output_dir: index).extract_changed(order)

        expect(touched).to include('OwnershipFleet::Car')
        expect(File.binread(File.join(index, 'generation.json'))).not_to eq(marker)
        expect(reader.find_unit('OwnershipFleet::Car', type: 'model').fetch('file_path')).to eq(@ownership_new)
        expect(differences(index, full_extraction)).to be_empty

        File.open(app_path(@ownership_old), 'a') { |file| file.puts('# unrelated surviving-file edit') }
        Woods::Extractor.new(output_dir: index).extract_changed([@ownership_old])
        expect(reader.find_unit('OwnershipFleet::Car', type: 'model').fetch('file_path')).to eq(@ownership_new)
        expect(differences(index, full_extraction)).to be_empty
      end

      it "keeps a file-derived lib move equivalent regardless of changed-path order, new first=#{new_first}" do
        old = write_file('lib/old_helpers.rb', 'class OwnershipHelpers; end')
        index = full_extraction
        write_file(old, 'class OwnershipOtherHelpers; end')
        fresh = write_file('lib/new_helpers.rb', 'class OwnershipHelpers; end')

        Woods::Extractor.new(output_dir: index).extract_changed(new_first ? [fresh, old] : [old, fresh])

        expect(differences(index, full_extraction)).to be_empty
      end
    end

    it 'does not publish a runtime move when eager loading was incomplete' do
      index = prepare_ownership_split
      marker = File.binread(File.join(index, 'generation.json'))
      split_runtime_owner
      allow(Rails.application).to receive(:eager_load!).and_raise(NameError, 'synthetic incomplete eager load')

      expect do
        Woods::Extractor.new(output_dir: index).extract_changed([@ownership_old, @ownership_new])
      end.to raise_error(Woods::IdentityCollisionError)
      expect(File.binread(File.join(index, 'generation.json'))).to eq(marker)
    end
  end

  it 'discovers a new nested job in a previously ordinary Ruby file' do
    path = write_file('app/models/new_hybrid_host.rb', 'class NewHybridHost; end')
    load app_path(path)
    index = full_extraction
    write_file(path, <<~RUBY)
      class NewHybridHost
        class NotifyJob < ApplicationJob
          def perform; :notification; end
        end
      end
    RUBY
    load app_path(path)

    touched = Woods::Extractor.new(output_dir: index).extract_changed([path])

    expect(touched).to include('NewHybridHost::NotifyJob')
    expect(differences(index, full_extraction)).to be_empty
  ensure
    Object.send(:remove_const, :NewHybridHost) if Object.const_defined?(:NewHybridHost, false)
  end

  describe 'nested hybrid ownership moves out of a surviving model file' do
    [false, true].each do |new_first|
      it "moves a nested job in either changed-path order, new first=#{new_first}" do
        old = write_file('app/models/hybrid_container.rb', <<~RUBY)
          class HybridContainer
            class NotifyJob < ApplicationJob
              def perform; :notification; end
            end
          end
        RUBY
        load app_path(old)
        index = full_extraction
        HybridContainer.send(:remove_const, :NotifyJob)
        write_file(old, 'class HybridContainer; end')
        fresh = write_file('app/jobs/hybrid_container/notify_job.rb', <<~RUBY)
          class HybridContainer::NotifyJob < ApplicationJob
            def perform; :notification; end
          end
        RUBY
        load app_path(fresh)

        touched = Woods::Extractor.new(output_dir: index).extract_changed(new_first ? [fresh, old] : [old, fresh])

        expect(touched).to include('HybridContainer::NotifyJob')
        expect(differences(index, full_extraction)).to be_empty
      ensure
        Object.send(:remove_const, :HybridContainer) if Object.const_defined?(:HybridContainer, false)
      end
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
