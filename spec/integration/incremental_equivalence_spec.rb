# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'

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
  ->(i) { "rake/rr_#{i}.rake" },                      # whole-app: a root rake directory
  ->(i) { "rake/lib/rs_#{i}.rb" },                    # and the support Ruby under it
  ->(i) { "config/locales/loc_#{i}.yml" },
  # Initializers require a new Rails boot and full extraction. Their task
  # equivalence is covered in incremental_runtime_spec, not this live process.
  ->(i) { "app/views/gen/erb_#{i}.html.erb" },
  ->(i) { "app/views/gen/hml_#{i}.html.haml" },
  ->(i) { "app/views/gen/jbd_#{i}.json.jbuilder" },
  ->(i) { "app/helpers/hlp_#{i}_helper.rb" },         # helper catalog: templates call hlp_<i>_label
  ->(i) { "spec/models/spc_#{i}_spec.rb" },
  ->(i) { "spec/features/ftr_#{i}_spec.rb" },         # routes exercised + test support references
  ->(i) { "spec/lib/tasks/rk_#{i}_spec.rb" },         # describes the rk_N rake namespace
  ->(i) { "spec/support/sup_#{i}.rb" },               # whole-app: test_support, re-runs test_mappings
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
  ->(i) { "app/graphql/resolvers/gqr_#{i}.rb" },
  # Documentation: resolved against the whole index after every run, so an
  # unchanged document gains and loses edges as the artifacts above come and go.
  ->(i) { "docs/gen/doc_#{i}.md" }
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
            "é"; ::ReferenceGraphTarget.generate
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
      expect(before.fetch('metadata').fetch('references')).to eq([])

      target_path = write_file('lib/reference_graph_target.rb', <<~RUBY)
        module ReferenceGraphTarget
          def self.generate
            raise 'reference analysis must never execute this method'
          end
        end
      RUBY
      load app_path(target_path)
      Woods::Extractor.new(output_dir: index).extract_changed([target_path])
      connected = lookup.call
      expect(connected.fetch('dependencies')).to include(
        'type' => 'lib', 'target' => 'ReferenceGraphTarget', 'via' => 'code_reference'
      )
      expected_references = [
        { 'line' => 8, 'column' => 4, 'length' => 'ReferenceGraphTarget'.bytesize,
          'target' => 'ReferenceGraphTarget', 'target_type' => 'lib',
          'kind' => 'constant', 'confidence' => 'verified', 'method' => 'generate' },
        { 'line' => 9, 'column' => 10, 'length' => '::ReferenceGraphTarget'.bytesize,
          'target' => 'ReferenceGraphTarget', 'target_type' => 'lib', 'kind' => 'constant', 'confidence' => 'verified',
          'method' => 'generate' }
      ]
      expect(connected.fetch('metadata').fetch('references')).to eq(expected_references)
      expect(connected.fetch('extracted_at')).to eq(before.fetch('extracted_at'))
      expected_references.each do |reference|
        source_line = connected.fetch('source_code').lines.fetch(reference.fetch('line') - 1)
        spelling = source_line.byteslice(reference.fetch('column'), reference.fetch('length'))
        expect(spelling.delete_prefix('::')).to eq(reference.fetch('target'))
      end
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('reverse').fetch('ReferenceGraphTarget')).to include('ReferenceGraphCaller')
      expect(differences(index, full_extraction)).to be_empty

      Woods::Extractor.new(output_dir: index).extract_changed([caller_path])
      expect(lookup.call).to eq(connected)
      expect(differences(index, full_extraction)).to be_empty

      File.unlink(app_path(target_path))
      Object.send(:remove_const, :ReferenceGraphTarget)
      Woods::Extractor.new(output_dir: index).extract_changed([target_path])
      expect(lookup.call.fetch('dependencies')).not_to include(hash_including('target' => 'ReferenceGraphTarget'))
      expect(lookup.call.fetch('metadata').fetch('references')).to eq([])
      expect(lookup.call.fetch('extracted_at')).to eq(before.fetch('extracted_at'))
      expect(read_json(index, 'dependency_graph.json').fetch('reverse').fetch('ReferenceGraphTarget', []))
        .not_to include('ReferenceGraphCaller')
      expect(differences(index, full_extraction)).to be_empty
    ensure
      Object.send(:remove_const, :ReferenceGraphCaller) if Object.const_defined?(:ReferenceGraphCaller, false)
      Object.send(:remove_const, :ReferenceGraphTarget) if Object.const_defined?(:ReferenceGraphTarget, false)
    end

    it 'reports every unit that calls a service object as its dependent, before and after a caller stops' do
      sources = {
        'app/services/gadget_pricer.rb' => "class GadgetPricer\n  def self.call(gadget)\n    gadget\n  end\nend\n",
        'app/services/gadget_batch.rb' => "class GadgetBatch\n  def run\n    GadgetPricer.call(nil)\n  end\nend\n",
        'app/models/gadget_quote.rb' => "class GadgetQuote\n  def total\n    GadgetPricer.call(self)\n  end\nend\n",
        'app/jobs/gadget_refresh_job.rb' =>
          "class GadgetRefreshJob < ApplicationJob\n  def perform\n    GadgetPricer.call(nil)\n  end\nend\n"
      }
      sources.each { |relative, source| load app_path(write_file(relative, source)) }
      index = full_extraction
      reverse = -> { read_json(index, 'dependency_graph.json').fetch('reverse').fetch('GadgetPricer', []) }
      expect(reverse.call).to include('GadgetBatch', 'GadgetQuote', 'GadgetRefreshJob')

      quote = write_file('app/models/gadget_quote.rb', "class GadgetQuote\n  def total\n    0\n  end\nend\n")
      load app_path(quote)
      Woods::Extractor.new(output_dir: index).extract_changed([quote])
      expect(reverse.call).to include('GadgetBatch', 'GadgetRefreshJob')
      expect(reverse.call).not_to include('GadgetQuote')
      expect(differences(index, full_extraction)).to be_empty
    ensure
      %i[GadgetPricer GadgetBatch GadgetQuote GadgetRefreshJob].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    it 'refreshes source references after a caller edit and retains its last generation after a parse failure' do
      caller_path = write_file('app/models/reference_refresh_caller.rb', <<~RUBY)
        class ReferenceRefreshCaller
          def execute
            ReferenceRefreshFirst.call
          end
        end
      RUBY
      first_path = write_file('lib/reference_refresh_first.rb', 'class ReferenceRefreshFirst; end')
      second_path = write_file('lib/reference_refresh_second.rb', 'class ReferenceRefreshSecond; end')
      [caller_path, first_path, second_path].each { |path| load app_path(path) }
      index = full_extraction
      require 'woods/mcp/index_reader'
      reader = Woods::MCP::IndexReader.new(index)
      initial = reader.find_unit('ReferenceRefreshCaller', type: 'poro')
      first_reference = { 'line' => 8, 'column' => 4, 'length' => 'ReferenceRefreshFirst'.bytesize,
                          'target' => 'ReferenceRefreshFirst', 'target_type' => 'lib',
                          'kind' => 'constant', 'confidence' => 'verified', 'method' => 'call' }
      expect(initial.fetch('metadata').fetch('references')).to eq([first_reference])

      # Same-length selector edit: coordinates, typed identity and graph edges stay fixed.
      write_file(caller_path, File.read(app_path(caller_path)).sub('.call', '.work'))
      load app_path(caller_path)
      generation = Woods::Generation.new(output_dir: index)
      token = generation.current.token
      expect { Woods::Extractor.new(output_dir: index).refresh(:events) }
        .to raise_error(Woods::SourceReferences::RebuildRequired, /unverified source/)
      expect(generation.current.token).to eq(token)
      expect(reader.find_unit('ReferenceRefreshCaller', type: 'poro')).to eq(initial)
      Woods::Extractor.new(output_dir: index).extract_changed([caller_path])
      selector_edit = reader.find_unit('ReferenceRefreshCaller', type: 'poro')
      first_reference = first_reference.merge('method' => 'work')
      expect(selector_edit.fetch('metadata').fetch('references')).to eq([first_reference])
      expect(selector_edit.fetch('dependencies')).to eq(initial.fetch('dependencies'))
      expect(differences(index, full_extraction)).to be_empty

      write_file(caller_path,
                 File.read(app_path(caller_path)).sub('ReferenceRefreshFirst.work', 'ReferenceRefreshSecond.work'))
      load app_path(caller_path)
      Woods::Extractor.new(output_dir: index).refresh(:poros)
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('reverse').fetch('ReferenceRefreshSecond')).to include('ReferenceRefreshCaller')
      expect(graph.fetch('reverse').fetch('ReferenceRefreshFirst', [])).not_to include('ReferenceRefreshCaller')
      refreshed = reader.find_unit('ReferenceRefreshCaller', type: 'poro')
      second_reference = first_reference.merge('length' => 'ReferenceRefreshSecond'.bytesize,
                                               'target' => 'ReferenceRefreshSecond')
      expect(refreshed.fetch('metadata').fetch('references')).to eq([second_reference])
      expect(differences(index, full_extraction)).to be_empty

      shifted = File.read(app_path(caller_path))
                    .sub('    ReferenceRefreshSecond.work', '      ReferenceRefreshSecond.work')
      write_file(caller_path, shifted)
      load app_path(caller_path)
      Woods::Extractor.new(output_dir: index).extract_changed([caller_path])
      moved = reader.find_unit('ReferenceRefreshCaller', type: 'poro')
      expect(moved.fetch('dependencies')).to eq(refreshed.fetch('dependencies'))
      expect(moved.fetch('metadata').fetch('references')).to eq([second_reference.merge('column' => 6)])
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
      expect(reader.find_unit('ReferenceRefreshCaller', type: 'poro')).to eq(moved)
    ensure
      %i[ReferenceRefreshCaller ReferenceRefreshFirst ReferenceRefreshSecond].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    it 'requires a full rebuild of format 6 before either public incremental writer can advance' do
      caller_path = write_file('app/models/reference_upgrade_caller.rb', <<~RUBY)
        class ReferenceUpgradeCaller
          def call
            MissingUpgradeTarget.call
          end
        end
      RUBY
      load app_path(caller_path)
      index = full_extraction
      generation = Woods::Generation.new(output_dir: index)
      token = generation.current.token
      cache_path = generation.payload_dir.join('source_references.json')
      cache = read_json(index, 'source_references.json')
      expect(cache.fetch('version')).to eq(7)
      cache['version'] = 6
      cache.fetch('files').each_value { |file| file.fetch('analysis').delete('macros') }
      File.binwrite(cache_path, JSON.generate(cache))
      previous_cache = File.binread(cache_path)
      previous_units = unit_snapshot(index)

      [-> { Woods::Extractor.new(output_dir: index).extract_changed([caller_path]) },
       -> { Woods::Extractor.new(output_dir: index).refresh(:poros) }].each do |operation|
        expect(&operation).to raise_error(Woods::SourceReferences::RebuildRequired, /woods:extract/)
        expect(generation.current.token).to eq(token)
        expect(File.binread(cache_path)).to eq(previous_cache)
        expect(unit_snapshot(index)).to eq(previous_units)
      end

      Woods::Extractor.new(output_dir: index).extract_all
      expect(read_json(index, 'source_references.json').fetch('version')).to eq(7)
      Woods::Extractor.new(output_dir: index).extract_changed([caller_path])
      expect(differences(index, full_extraction)).to be_empty
    ensure
      Object.send(:remove_const, :ReferenceUpgradeCaller) if Object.const_defined?(:ReferenceUpgradeCaller, false)
    end
  end

  describe 'component reference callers (#655)' do
    def unit_dependencies(index, type, identifier)
      require 'woods/mcp/index_reader'
      Woods::MCP::IndexReader.new(index).find_unit(identifier, type: type).fetch('dependencies')
    end

    def reverse_edges(index, target)
      read_json(index, 'dependency_graph.json').fetch('reverse').fetch(target, [])
    end

    def reference(type, target)
      { 'type' => type, 'target' => target, 'via' => 'code_reference' }
    end

    let(:card_path) { 'app/views/ui/card_component.rb' }
    let(:pristine_card) { File.read(app_path(card_path), encoding: 'UTF-8') }

    def write_card(call_body)
      write_file(card_path, <<~RUBY)
        module Ui
          class CardComponent < ApplicationComponent
            def initialize(title:, subtitle: nil)
              @title = title
              @subtitle = subtitle
              super()
            end

            def call
              #{call_body}
            end
          end
        end
      RUBY
      load app_path(card_path)
    end

    it 'adds and withdraws the edges of a component that gains and loses a model reference' do
      index = full_extraction
      expect(unit_dependencies(index, 'component', 'Ui::CardComponent'))
        .not_to include(hash_including('via' => 'code_reference'))

      pristine = pristine_card
      write_card('[@title, Post.count, SignatureService.name, BadgeComponent.name].join')
      Woods::Extractor.new(output_dir: index).extract_changed([card_path])
      edges = unit_dependencies(index, 'component', 'Ui::CardComponent')
      expect(edges).to include(reference('model', 'Post'), reference('service', 'SignatureService'))
      expect(edges).not_to include(reference('component', 'BadgeComponent'))
      expect(reverse_edges(index, 'SignatureService')).to include('Ui::CardComponent')
      expect(reverse_edges(index, 'Post')).to include('Ui::CardComponent')
      expect(differences(index, full_extraction)).to be_empty

      write_file(card_path, pristine)
      load app_path(card_path)
      Woods::Extractor.new(output_dir: index).extract_changed([card_path])
      expect(unit_dependencies(index, 'component', 'Ui::CardComponent'))
        .not_to include(hash_including('via' => 'code_reference'))
      expect(reverse_edges(index, 'SignatureService')).not_to include('Ui::CardComponent')
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'retargets an unchanged component when the service it names appears and disappears' do
      write_card('LaterCardQuote.for(@title)')
      index = full_extraction
      expect(unit_dependencies(index, 'component', 'Ui::CardComponent')).not_to include(
        hash_including('target' => 'LaterCardQuote')
      )

      quote_path = write_file('app/services/later_card_quote.rb',
                              "class LaterCardQuote\n  def self.for(title) = title\nend\n")
      load app_path(quote_path)
      Woods::Extractor.new(output_dir: index).extract_changed([quote_path])
      expect(unit_dependencies(index, 'component', 'Ui::CardComponent'))
        .to include(reference('service', 'LaterCardQuote'))
      expect(reverse_edges(index, 'LaterCardQuote')).to include('Ui::CardComponent')
      expect(differences(index, full_extraction)).to be_empty

      delete_file(quote_path)
      Object.send(:remove_const, :LaterCardQuote)
      Woods::Extractor.new(output_dir: index).extract_changed([quote_path])
      expect(unit_dependencies(index, 'component', 'Ui::CardComponent')).not_to include(
        hash_including('target' => 'LaterCardQuote')
      )
      expect(differences(index, full_extraction)).to be_empty
    ensure
      Object.send(:remove_const, :LaterCardQuote) if Object.const_defined?(:LaterCardQuote, false)
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

  # Operation documents need the real graphql gem and a booted schema; this
  # process loads neither, so the scenarios run in their own Rails boot.
  it 'keeps GraphQL operation documents equivalent through document, fragment and schema changes' do
    script = File.expand_path('../fixtures/graphql_operations/boot.rb', __dir__)
    output, error, status = Open3.capture3(RbConfig.ruby, '-Ilib', script)
    expect(status.success?).to be(true), "#{error}\n#{output}"
    result = JSON.parse(output.lines.last.force_encoding('UTF-8'))
    expect(result.fetch('checks')).to include(
      'every edge target is a published unit',
      'schema dump and unparseable document appear in the skipped-files report with reasons',
      'dependents of a mutation list the client document that calls it',
      'repeat full extraction is identical',
      'document edit full/incremental equivalence',
      'document creation full/incremental equivalence',
      'duplicate fragment full/incremental equivalence',
      'document deletion full/incremental equivalence',
      'schema drift full/incremental equivalence',
      'refresh full equivalence'
    )
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

  # Annotated source_code shifts lines away from the file; the map back to the
  # file is recorded while the absolute path is still readable, on the full
  # path's normalization phase and on each incremental write.
  describe 'source line maps' do
    def line_map(dir, identifier)
      payload = Woods::Generation.new(output_dir: dir).payload_dir
      Dir[File.join(payload, 'services', '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
        .find { |unit| unit['identifier'] == identifier }
        &.dig('metadata', 'source_line_map')
    end

    it 'records the same map for an annotated unit through full and incremental runs' do
      require 'woods/source_line_map'
      path = write_file('app/services/line_map_service.rb', service_source('LineMapService'))
      index = full_extraction
      expect(line_map(index, 'LineMapService')).not_to be_nil

      edited = "# frozen_string_literal: true\n\n#{service_source('LineMapService', dependency: 'Post')}"
      write_file(path, edited)
      Woods::Extractor.new(output_dir: index).extract_changed([path])
      oracle = full_extraction

      maintained = line_map(index, 'LineMapService')
      expect(maintained).to eq(line_map(oracle, 'LineMapService'))
      source = Dir[File.join(Woods::Generation.new(output_dir: index).payload_dir, 'services', '*.json')]
               .map { |file| JSON.parse(File.read(file, encoding: 'UTF-8')) }
               .find { |unit| unit.is_a?(Hash) && unit['identifier'] == 'LineMapService' }.fetch('source_code')
      def_line = source.lines.index { |line| line.include?('def call') } + 1
      expect(Woods::SourceLineMap.translate(maintained, def_line)).to eq(4)
      expect(differences(index, oracle)).to be_empty
    end
  end

  # Source size (#810): the file's line counts on the node, and the package
  # totals in graph_analysis.json, follow edits and package changes on both paths.
  describe 'source sizes' do
    def node(dir, identifier)
      read_json(dir, 'dependency_graph.json').fetch('nodes').fetch(identifier)
    end

    it 'counts the same lines through full and incremental runs as a file and a package change' do
      path = write_file('app/services/sized_service.rb', service_source('SizedService'))
      index = full_extraction
      expect(node(index, 'SizedService')).to include('lines' => 5, 'loc' => 5)

      write_file(path, "# frozen_string_literal: true\n\n#{service_source('SizedService', dependency: 'Post')}\n")
      package = write_file('app/services/package.yml', "enforce_dependencies: false\n")
      Woods::Extractor.new(output_dir: index).extract_changed([path, package])
      oracle = full_extraction

      expect(node(index, 'SizedService')).to include('lines' => 8, 'loc' => 6, 'package' => 'app/services')
      expect(read_json(index, 'graph_analysis.json').fetch('package_sizes').fetch('app/services'))
        .to include('types' => include('service' => be >= 6))
      expect(differences(index, oracle)).to be_empty
    end
  end

  it 'omits ignored configuration YAML in both full and incremental extraction' do
    _out, err, status = Open3.capture3(*Woods::GitCommand.argv(@app_root, 'init', '--quiet'))
    raise err unless status.success?

    write_file('.gitignore', "config/settings.local.yml\n")
    _out, err, status = Open3.capture3(*Woods::GitCommand.argv(@app_root, 'add', '.'))
    raise err unless status.success?

    baseline = full_extraction
    path = write_file('config/settings.local.yml', "private_local_key: withheld\n")
    Woods::Extractor.new(output_dir: baseline).extract_changed([path])
    full = full_extraction
    expect(differences(baseline, full)).to be_empty
    [baseline, full].each do |index|
      payload = Woods::Generation.new(output_dir: index).payload_dir
      expect(index_snapshot(index).fetch('config_files', []).map { |unit| unit['identifier'] }).not_to include(path)
      expect(Woods::SkippedFiles.read(payload).fetch('files')).to include('path' => path, 'reason' => 'git_ignored')
    end
  ensure
    FileUtils.rm_rf(app_path('.git'))
    FileUtils.rm_f(app_path('.gitignore'))
  end

  describe 'commit table (W-3)' do
    def app_git(*args, author: 'Leah Armstrong')
      env = { 'GIT_AUTHOR_NAME' => author, 'GIT_AUTHOR_EMAIL' => 'author@example.invalid',
              'GIT_COMMITTER_NAME' => author, 'GIT_COMMITTER_EMAIL' => 'author@example.invalid' }
      out, err, status = Open3.capture3(env, *Woods::GitCommand.argv(@app_root, *args))
      raise err unless status.success?

      out.strip
    end

    def commit_table(index)
      Woods::GitCommitTable.read(Woods::Generation.new(output_dir: index).payload_dir)
    end

    it 'publishes no table for an application without git history, on either path' do
      index = full_extraction
      changed = write_file('app/services/no_history_service.rb', service_source('NoHistoryService'))
      Woods::Extractor.new(output_dir: index).extract_changed([changed])

      expect(commit_table(index)).to be_nil
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'keeps the table equivalent to a full run as files change and HEAD moves' do
      app_git('init', '--quiet', '-b', 'main')
      QuietGit.configure(@app_root)
      app_git('add', '.')
      app_git('commit', '-qm', 'Initial application')
      index = full_extraction
      expect(commit_table(index)['paths']).to include('app/models/post.rb')

      service = write_file('app/services/digest_service.rb', service_source('DigestService', dependency: 'Post'))
      app_git('add', '.')
      app_git('commit', '-qm', 'Send digests', author: 'Sam Okafor-Whitfield')
      Woods::Extractor.new(output_dir: index).extract_changed([service])
      expect(differences(index, full_extraction)).to be_empty
      expect(commit_table(index)['paths'].fetch(service)).to eq([app_git('rev-parse', 'HEAD')])

      # Extracted before it is committed, then committed: the commit moves
      # HEAD under an unchanged unit, and the commit range names the file
      # again (as woods:incremental's git range does).
      edited = write_file(service, service_source('DigestService', dependency: 'Comment'))
      Woods::Extractor.new(output_dir: index).extract_changed([edited])
      app_git('commit', '-qam', 'Digest comments too')
      Woods::Extractor.new(output_dir: index).extract_changed([edited])

      table = commit_table(index)
      expect(table['head']).to eq(app_git('rev-parse', 'HEAD'))
      expect(table['commits'].map { |row| row['message'] }.first(2)).to eq(['Digest comments too', 'Send digests'])
      expect(differences(index, full_extraction)).to be_empty
    ensure
      FileUtils.rm_rf(app_path('.git'))
    end
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

  describe 'configuration drift from the baseline' do
    def consumer_units(index_dir)
      Dir[File.join(Woods::Generation.new(output_dir: index_dir).payload_dir, 'external_consumers', '*.json')]
        .reject { |path| path.end_with?('_index.json') }
    end

    it 'refuses an incremental that leaves out declared consumers and stays equivalent once they match again' do
      Woods.configuration.external_table_consumers = { 'lantern-shop' => %w[posts] }
      index_dir = full_extraction
      generation = Woods::Generation.new(output_dir: index_dir)
      published = generation.current.number
      expect(consumer_units(index_dir)).not_to be_empty

      Woods.configuration.external_table_consumers = {}
      expect { Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/models/post.rb']) }
        .to raise_error(Woods::ExtractionError, /external_table_consumers.*woods:extract/m)
      expect(generation.current.number).to eq(published)
      expect(consumer_units(index_dir)).not_to be_empty

      Woods.configuration.external_table_consumers = { 'lantern-shop' => %w[posts] }
      Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/models/post.rb'])
      expect(differences(index_dir, full_extraction)).to be_empty
    ensure
      Woods.configuration.external_table_consumers = {}
    end
  end

  describe 'configured event roots' do
    around do |example|
      Woods.configuration.event_paths = %w[app lib]
      example.run
    ensure
      Woods.configuration.event_paths = %w[app]
    end

    def ledger_bus(publishes:)
      call = publishes ? "      ActiveSupport::Notifications.instrument('ledger.settled')\n" : "      :ok\n"
      "module Ledger\n  class Bus\n    def settle\n#{call}    end\n  end\nend\n"
    end

    it 'tracks a lib/ publisher gaining, losing and regaining its call, then deletion' do
      write_file('app/services/settlement_listener.rb', <<~RUBY)
        class SettlementListener
          ActiveSupport::Notifications.subscribe('ledger.settled') {}
        end
      RUBY

      run_sequence([
                     -> { write_file('lib/ledger/bus.rb', ledger_bus(publishes: true)) },
                     -> { write_file('lib/ledger/bus.rb', ledger_bus(publishes: false)) },
                     -> { write_file('lib/ledger/bus.rb', ledger_bus(publishes: true)) },
                     -> { delete_file('lib/ledger/bus.rb') }
                   ])
    end
  end

  describe 'rake roots outside lib/tasks' do
    def container_helper(shells_out:)
      body = shells_out ? "    sh \"docker compose exec app \#{command}\"\n" : "    command\n"
      "module Container\n  def exec_in_container(command)\n#{body}  end\nend\n"
    end

    it 'tracks a root rake file, its support file and an enhancement through edits and deletion' do
      codegen = "namespace :graph do\n  task(:codegen) { exec_in_container 'yarn run graph-codegen' }\nend\n"

      run_sequence([
                     -> { write_file('rake/graph.rake', codegen) },
                     -> { write_file('rake/lib/container.rb', container_helper(shells_out: true)) },
                     lambda {
                       write_file('lib/tasks/hooks.rake', "Rake::Task['graph:codegen'].enhance(['graph:clean'])\n")
                     },
                     -> { write_file('rake/lib/container.rb', container_helper(shells_out: false)) },
                     -> { delete_file('rake/lib/container.rb') },
                     -> { delete_file('rake/graph.rake') },
                     lambda {
                       write_file('lib/tasks/hooks.rake', "Rake::Task['graph:codegen'].enhance do\n  sh 'bin/x'\nend\n")
                     },
                     -> { delete_file('lib/tasks/hooks.rake') }
                   ])
    end

    it 'tracks a task class, a file task and a rule in a nested root file' do
      run_sequence([
                     lambda {
                       write_file('rake/dev/docs.rake', <<~RAKE)
                         if defined?(RSpec)
                           RSpec::Core::RakeTask.new(:docs) { |t| t.pattern = 'spec/docs/**/*_spec.rb' }
                         end
                         file 'public/app.css' => ['app/app.scss']
                         rule '.o' => '.c'
                       RAKE
                     },
                     -> { write_file('rake/dev/docs.rake', "RSpec::Core::RakeTask.new(:docs)\n") },
                     -> { delete_file('rake/dev/docs.rake') }
                   ])
    end

    it 'keeps a task reopened in a second file mapped to both files when only the second changes' do
      write_file('lib/tasks/widgets.rake', "task :backfill_widgets do\n  puts 'first'\nend\n")
      reopened = 'lib/tasks/one_offs/widgets_again.rake'

      index = run_sequence([
                             -> { write_file(reopened, "task :backfill_widgets do\n  puts 'second'\nend\n") },
                             -> { write_file(reopened, "task :backfill_widgets do\n  sh 'bin/widgets'\nend\n") }
                           ])

      file_map = read_json(index, 'dependency_graph.json').fetch('file_map')
      expect(file_map.fetch(reopened)).to eq(['backfill_widgets'])
      expect(file_map.fetch('lib/tasks/widgets.rake')).to eq(['backfill_widgets'])
      require 'woods/resilience/index_validator'
      [index, full_extraction].each do |directory|
        expect(Woods::Resilience::IndexValidator.new(index_dir: directory).validate.errors).to be_empty
      end

      run_sequence([-> { delete_file(reopened) }])
    end

    it 'publishes identical bytes from two full extractions of the same rake tree' do
      write_file('rake/graph.rake', "task(:codegen) { exec_in_container 'yarn run graph-codegen' }\n")
      write_file('rake/lib/container.rb', container_helper(shells_out: true))
      write_file('lib/tasks/hooks.rake', "Rake::Task['codegen'].enhance(['clean'])\n")

      expect(differences(full_extraction, full_extraction)).to be_empty
    end

    context 'with a configured root' do
      around do |example|
        Woods.configuration.rake_task_paths = ['ops/*.rake']
        Woods::PathDispatcher.reset!
        example.run
      ensure
        Woods.configuration.rake_task_paths = Woods::Extractors::RakeTaskPaths::DEFAULT_PATHS
        Woods::PathDispatcher.reset!
      end

      it 'tracks tasks and support Ruby under the configured directory only' do
        run_sequence([
                       -> { write_file('ops/deploy.rake', rake_source('deploy', %w[ship])) },
                       -> { write_file('ops/support/shell.rb', container_helper(shells_out: true)) },
                       -> { write_file('ops/deploy.rake', rake_source('deploy', %w[ship verify])) },
                       -> { delete_file('ops/support/shell.rb') },
                       -> { delete_file('ops/deploy.rake') }
                     ])
      end
    end
  end

  describe 'JavaScript modules and the names templates reference them by (#679)' do
    def unit_json(dir, type_dir, identifier)
      payload = Woods::Generation.new(output_dir: dir).payload_dir
      Dir[File.join(payload, type_dir, '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
        .find { |unit| unit['identifier'] == identifier }
    end

    def js_edges(dir, type_dir, identifier)
      unit_json(dir, type_dir, identifier).fetch('dependencies')
                                          .select { |dep| dep['type'] == 'js_module' }
                                          .map { |dep| dep.values_at('target', 'via') }
    end

    def write_consumers
      write_file('app/views/posts/panel.html.erb', <<~ERB)
        <div x-data="dropdown({ open: false })" data-controller="clipboard">
          <x-shipment-card sku="1"></x-shipment-card>
        </div>
      ERB
      write_file('app/views/posts/_badge.html.haml', "%span{ data: { controller: \"clipboard\" } }\n")
      write_file('app/components/badge_component.rb', <<~RUBY)
        class BadgeComponent < ApplicationComponent
          def initialize(label:)
            @label = label
            super()
          end

          def call
            div(x_data: "dropdown", data_controller: "clipboard") { @label.to_s }
          end
        end
      RUBY
    end

    stimulus = "import { Controller } from \"@hotwired/stimulus\"\nexport default class extends Controller {}\n"

    it 'links unchanged templates and components as modules appear, move, and disappear' do
      write_consumers

      index = run_sequence(
        [
          -> { write_file('app/javascript/controllers/clipboard_controller.js', stimulus) },
          lambda {
            [write_file('app/javascript/alpine/dropdown.js', "export default () => ({ open: false })\n"),
             write_file('app/javascript/application.js',
                        "import dropdown from \"./alpine/dropdown\"\nAlpine.data(\"dropdown\", dropdown)\n")]
          },
          # A body edit: no name moves, so no consumer is re-run wholesale.
          -> { write_file('app/javascript/alpine/dropdown.js', "export default () => ({ open: true })\n") },
          # The registration becomes inline: the name moves to the registering module.
          -> { write_file('app/javascript/application.js', "Alpine.data(\"dropdown\", () => ({}))\n") },
          lambda {
            write_file('app/javascript/components/shipment-card.tsx',
                       "@Component({ tag: \"x-shipment-card\" })\nexport class ShipmentCard {}\n")
          },
          # A rename is a delete plus an add: the convention name changes with the path.
          lambda {
            [delete_file('app/javascript/controllers/clipboard_controller.js'),
             write_file('app/javascript/controllers/copier_controller.js', stimulus)]
          },
          -> { write_file('app/views/posts/_badge.html.haml', "%span{ data: { controller: \"copier\" } }\n") }
        ]
      )

      expect(js_edges(index, 'view_templates', 'posts/panel.html.erb')).to eq(
        [['app/javascript/application.js', 'alpine_data'],
         ['app/javascript/components/shipment-card.tsx', 'custom_element']]
      )
      panel = unit_json(index, 'view_templates', 'posts/panel.html.erb')
      expect(panel.dig('metadata', 'unresolved_frontend_references'))
        .to eq([{ 'kind' => 'stimulus_controller', 'name' => 'clipboard' }])
      expect(js_edges(index, 'view_templates', 'posts/_badge.html.haml'))
        .to eq([['app/javascript/controllers/copier_controller.js', 'stimulus_controller']])
      expect(js_edges(index, 'components', 'BadgeComponent')).to eq([['app/javascript/application.js', 'alpine_data']])
      dependents = unit_json(index, 'js_modules', 'app/javascript/application.js').fetch('dependents')
      expect(dependents.map { |d| d['identifier'] }).to include('BadgeComponent', 'posts/panel.html.erb')
    end

    it 'drops every edge and unit when the last module is deleted' do
      write_consumers
      write_file('app/javascript/controllers/clipboard_controller.js', stimulus)

      index = run_sequence([-> { delete_file('app/javascript/controllers/clipboard_controller.js') }])

      expect(js_edges(index, 'view_templates', 'posts/panel.html.erb')).to eq([])
      expect(unit_json(index, 'js_modules', 'app/javascript/controllers/clipboard_controller.js')).to be_nil
    end

    it 'tracks import edges as the imported module is deleted, recreated and re-pointed' do
      write_file('app/javascript/entry.js', "import total from \"./ledger/total\"\nexport default total\n")
      write_file('app/javascript/ledger/total.js', "export default 1\n")

      index = run_sequence(
        [
          -> { delete_file('app/javascript/ledger/total.js') },
          -> { write_file('app/javascript/ledger/total.ts', "export default 2\n") },
          -> { write_file('app/javascript/ledger/index.js', "export { default } from \"./total\"\n") },
          -> { write_file('app/javascript/entry.js', "import total from \"./ledger\"\nexport default total\n") }
        ]
      )

      expect(js_edges(index, 'js_modules',
                      'app/javascript/entry.js')).to eq([['app/javascript/ledger/index.js', 'import']])
    end

    it 'omits and restores source as a module crosses the size cap' do
      big = "export const big = 1\n#{"// padding\n" * 20_000}"

      index = run_sequence(
        [
          -> { write_file('app/javascript/big.js', big) },
          -> { write_file('app/javascript/big.js', "export const big = 1\n") },
          -> { write_file('app/javascript/big.js', big) }
        ]
      )

      expect(unit_json(index, 'js_modules', 'app/javascript/big.js')).to include('source_code' => '')
      expect(unit_json(index, 'js_modules',
                       'app/javascript/big.js').fetch('metadata')).to include('source_omitted' => true)
    end

    it 'ignores vendored and generated JavaScript in both modes' do
      index = run_sequence(
        [
          -> { write_file('app/javascript/vendor/chart.js', "window.dropdown = function () {}\n") },
          -> { write_file('app/assets/javascripts/builds/application.js', "Alpine.data(\"dropdown\", () => ({}))\n") },
          -> { write_file('app/assets/javascripts/legacy.js', "window.dropdown = function () { return {} }\n") }
        ]
      )

      payload = Woods::Generation.new(output_dir: index).payload_dir
      expect(JSON.parse(File.read(File.join(payload, 'js_modules', '_index.json'))).map { |u| u['identifier'] })
        .to eq(['app/assets/javascripts/legacy.js'])
    end

    it 'agrees with a full extraction when a name moves outside a capped blast radius' do
      Woods.configuration.incremental_blast_radius_depth = 1
      write_consumers
      write_file('app/javascript/alpine/a.js', "export default () => ({})\n")
      write_file('app/javascript/alpine/b.js', "export default () => ({})\n")
      write_file('app/javascript/application.js',
                 "import dropdown from \"./alpine/a\"\nAlpine.data(\"dropdown\", dropdown)\n")

      index = run_sequence(
        [
          lambda {
            write_file('app/javascript/application.js',
                       "import dropdown from \"./alpine/b\"\nAlpine.data(\"dropdown\", dropdown)\n")
          }
        ]
      )

      expect(js_edges(index, 'view_templates',
                      'posts/panel.html.erb')).to eq([['app/javascript/alpine/b.js', 'alpine_data']])
    ensure
      Woods.configuration.incremental_blast_radius_depth = nil
    end

    it 're-runs the name consumers wholesale only when the name map moved' do
      write_consumers
      write_file('app/javascript/controllers/clipboard_controller.js', stimulus)
      write_file('app/javascript/util.js', "export const one = 1\n")
      index = full_extraction
      reruns = []
      templates = Woods::Extractors::ViewTemplateExtractor
      allow_any_instance_of(templates).to receive(:extract_all).and_wrap_original do |original|
        reruns << :view_templates
        original.call
      end

      write_file('app/javascript/util.js', "export const one = 2\n")
      Woods::Extractor.new(output_dir: index).extract_changed(['app/javascript/util.js'])
      expect(reruns).to eq([])

      write_file('app/javascript/util.js', "Alpine.data(\"dropdown\", () => ({}))\n")
      Woods::Extractor.new(output_dir: index).extract_changed(['app/javascript/util.js'])
      expect(reruns).to eq([:view_templates])
      allow_any_instance_of(templates).to receive(:extract_all).and_call_original
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'refreshes js_modules by name and re-resolves the consumers' do
      write_consumers
      index = full_extraction
      write_file('app/javascript/controllers/clipboard_controller.js', stimulus)

      result = Woods::Extractor.new(output_dir: index).refresh(:js_modules)

      expect(result[:types]).to eq(%i[js_modules components view_components view_templates])
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'is byte-identical across repeat full extractions' do
      write_consumers
      write_file('app/javascript/controllers/clipboard_controller.js', stimulus)
      write_file('app/javascript/application.js', "import \"./controllers/clipboard_controller\"\n")

      first = full_extraction
      second = full_extraction

      expect(differences(first, second)).to be_empty
      %w[js_modules/_index.json view_templates/_index.json].each do |relative|
        files = [first, second].map { |dir| File.read(Woods::Generation.new(output_dir: dir).payload_dir.join(relative)) }
        expect(files.first).to eq(files.last)
      end
    end

    describe 'with configured javascript_paths' do
      around do |example|
        Woods.configuration.javascript_paths = ['frontend/**/*.{ts,tsx}']
        example.run
      ensure
        Woods.configuration.javascript_paths = Woods::JavascriptPaths::DEFAULT_GLOBS
      end

      it 'indexes a configured root and ignores the default one, through create, edit and delete' do
        write_consumers
        write_file('app/javascript/controllers/clipboard_controller.js', stimulus)

        index = run_sequence(
          [
            lambda {
              write_file('frontend/components/shipment-card.tsx',
                         "@Component({ tag: \"x-shipment-card\" })\nexport class ShipmentCard {}\n")
            },
            lambda {
              write_file('frontend/components/shipment-card.tsx',
                         "@Component({ tag: \"x-parcel-card\" })\nexport class ShipmentCard {}\n")
            },
            -> { write_file('frontend/controllers/clipboard_controller.ts', stimulus) },
            -> { delete_file('frontend/components/shipment-card.tsx') }
          ]
        )

        expect(js_edges(index, 'view_templates', 'posts/panel.html.erb'))
          .to eq([['frontend/controllers/clipboard_controller.ts', 'stimulus_controller']])
        expect(unit_json(index, 'js_modules', 'app/javascript/controllers/clipboard_controller.js')).to be_nil
      end
    end
  end

  describe 'one unit per class' do
    def remove_constants(*names)
      names.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    end

    def type_index(index)
      read_json(index, 'dependency_graph.json').fetch('type_index')
    end

    def unit_edges(index, type, identifier)
      payload = Woods::Generation.new(output_dir: index).payload_dir
      Dir[File.join(payload, type, '*.json')].filter_map do |path|
        document = JSON.parse(File.read(path, encoding: 'UTF-8'))
        document.fetch('dependencies') if document.is_a?(Hash) && document['identifier'] == identifier
      end.first
    end

    after do
      remove_constants(:OwnershipStorage, :OwnershipHost, :OwnershipBaseSerializer, :OwnershipSummary,
                       :OwnershipAccount)
    end

    def write_storage_host(include_storage:)
      remove_constants(:OwnershipHost)
      path = write_file('app/models/ownership_host.rb', <<~RUBY)
        class OwnershipHost < ApplicationRecord
          self.table_name = 'posts'
          #{'include OwnershipStorage' if include_storage}
        end
      RUBY
      load app_path(path)
      path
    end

    it 'publishes a lib module a model includes as a concern only, as the include comes and goes' do
      load app_path(write_file('lib/ownership_storage.rb', "module OwnershipStorage\n  def upload; end\nend\n"))
      host = write_storage_host(include_storage: false)
      index = full_extraction
      expect(type_index(index).fetch('lib')).to include('OwnershipStorage')

      [true, false].each do |included|
        write_storage_host(include_storage: included)
        Woods::Extractor.new(output_dir: index).extract_changed([host])
        types = type_index(index)
        expect(types.fetch(included ? 'concern' : 'lib')).to include('OwnershipStorage')
        expect(types.fetch(included ? 'lib' : 'concern', [])).not_to include('OwnershipStorage')
        expect(differences(index, full_extraction)).to be_empty
      end
    end

    it 'publishes a descendant of an application serializer base as a serializer only' do
      load app_path(write_file('app/serializers/ownership_base_serializer.rb', "class OwnershipBaseSerializer\nend\n"))
      summary = 'app/models/ownership_summary.rb'
      body = ->(extra) { "class OwnershipSummary < OwnershipBaseSerializer\n  def call = #{extra}\nend\n" }
      index = run_sequence([
                             -> { load app_path(write_file(summary, body.call(1))) && summary },
                             -> { write_file(summary, body.call(2)) }
                           ])

      types = type_index(index)
      expect(types.fetch('serializer')).to include('OwnershipSummary')
      expect(types.fetch('poro', [])).not_to include('OwnershipSummary')
    end

    it 'gives a nested job only the edges written in its own class body' do
      path = 'app/models/ownership_account.rb'
      body = lambda do |note|
        <<~RUBY
          class OwnershipAccount
            def finish
              PublishPostJob.perform_later(1) # #{note}
              Post.where(id: 1)
            end

            class OwnershipClearJob < ApplicationJob
              def perform(id) = id
            end
          end
        RUBY
      end
      index = run_sequence([
                             -> { load app_path(write_file(path, body.call('one'))) && path },
                             -> { write_file(path, body.call('two')) }
                           ])

      edges = unit_edges(index, 'jobs', 'OwnershipAccount::OwnershipClearJob')
      expect(edges.map { |edge| edge['target'] }).not_to include('PublishPostJob', 'Post')
    end
  end

  describe 'method effects (#680)' do
    def unit_document(dir, type, identifier)
      payload = Woods::Generation.new(output_dir: dir).payload_dir
      Dir[File.join(payload, type, '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
        .find { |unit| unit.is_a?(Hash) && unit['identifier'] == identifier }
    end

    def enqueue_edge(document)
      document.fetch('dependencies').find { |dep| dep['target'] == 'PublishPostJob' && dep['via'] == 'job_enqueue' }
    end

    def edge_identities(document)
      document.fetch('dependencies').map { |dep| dep.values_at('type', 'target', 'via') }
    end

    def ledger_service(methods)
      bodies = methods.map { |name, body| "  def #{name}(post)\n    #{body}\n  end\n" }.join("\n")
      "class LedgerService\n#{bodies}end\n"
    end

    let(:post_model) do
      <<~RUBY
        class Post < ApplicationRecord
          has_many :comments, dependent: :destroy

          validates :title, presence: true

          scope :recent, -> { order(created_at: :desc) }

          before_save :normalize_title

          def normalize_title
            self.title = title.to_s.strip
          end

          def publish!
            PublishPostJob.perform_later(self)
          end
        end
      RUBY
    end

    it 'follows a method gaining, moving and losing an enqueue, in a service and a model' do
      service = 'app/services/ledger_service.rb'
      enqueue = 'PublishPostJob.perform_later(post)'
      index = run_sequence(
        [
          -> { write_file(service, ledger_service('post_all' => enqueue)) },
          lambda {
            write_file(service, ledger_service('post_all' => 'retry_all(post)', 'retry_all' => enqueue,
                                               'sign' => 'SignatureService.new.call(post)'))
          },
          -> { write_file('app/models/post.rb', post_model) }
        ]
      )

      document = unit_document(index, 'services', 'LedgerService')
      expect(document.dig('metadata', 'method_effects').keys).to eq(%w[post_all retry_all sign])
      expect(edge_identities(document)).to eq(edge_identities(document).uniq)
      expect(document.fetch('dependencies'))
        .to include('type' => 'service', 'target' => 'SignatureService', 'via' => 'code_reference', 'through' => 'sign')
      expect(document.dig('metadata', 'method_effects', 'post_all', 'via_method'))
        .to eq('retry_all' => { 'jobs_enqueued' => ['PublishPostJob'] })
      expect(enqueue_edge(document)).to include('through' => 'post_all, retry_all')

      model = unit_document(index, 'models', 'Post')
      expect(model.dig('metadata', 'method_effects').keys).to eq(%w[normalize_title publish!])
      expect(enqueue_edge(model)).to include('through' => 'publish!')
      expect(edge_identities(model)).to eq(edge_identities(model).uniq)
    end

    it 'keeps declaration spans and the method table equivalent as a model changes (#751, #752)' do
      model = 'app/models/post.rb'
      index = run_sequence(
        [
          -> { write_file(model, post_model) },
          -> { write_file(model, post_model.sub("  def publish!\n", "  private\n\n  def publish!\n")) }
        ]
      )

      document = unit_document(index, 'models', 'Post')
      spans = document.dig('metadata', 'references').map { |span| span.values_at('kind', 'target', 'method') }
      expect(spans).to include(['association', 'Comment', nil], %w[callback_method Post normalize_title],
                               %w[scope Post recent])
      methods = document.dig('metadata', 'methods').map { |entry| entry.values_at('name', 'visibility', 'owner') }
      expect(methods).to eq([%w[normalize_title public Post], %w[publish! private Post]])
    end

    it 'drops the map and the edge annotation when the last effect goes' do
      service = 'app/services/ledger_service.rb'
      index = run_sequence(
        [
          -> { write_file(service, ledger_service('post_all' => 'PublishPostJob.perform_later(post)')) },
          -> { write_file(service, ledger_service('post_all' => 'post.touch')) }
        ]
      )

      document = unit_document(index, 'services', 'LedgerService')
      expect(document.fetch('metadata')).not_to have_key('method_effects')
      expect(enqueue_edge(document)).to be_nil
    end

    it 'writes byte-identical unit documents on a repeat full extraction' do
      write_file('app/services/ledger_service.rb', ledger_service('post_all' => 'PublishPostJob.perform_later(post)'))
      write_file('app/models/post.rb', post_model)

      expect(differences(full_extraction, full_extraction)).to be_empty
    end
  end

  describe 'mailer callback fact freshness' do
    %i[parent concern].each do |owner_kind|
      it "refreshes child action facts when only the #{owner_kind} callback body changes" do
        created_directories = %w[app/mailers app/mailers/concerns].reject do |relative|
          File.directory?(app_path(relative))
        end
        prefix = "#{owner_kind.to_s.camelize}FactFresh"
        base_name = "#{prefix}BaseMailer"
        child_name = "#{prefix}Mailer"
        concern_name = "#{prefix}Callbacks"
        base = "app/mailers/#{base_name.underscore}.rb"
        child = "app/mailers/#{child_name.underscore}.rb"
        owner = owner_kind == :parent ? base : "app/mailers/concerns/#{concern_name.underscore}.rb"
        owner_source = lambda do |body|
          declaration = owner_kind == :parent ? "class #{base_name} < ActionMailer::Base" : "module #{concern_name}"
          "#{declaration}\n  private\n  def set_viewer\n#{body}  end\nend\n"
        end
        write_owner = lambda do |body|
          write_file(owner, owner_source.call(body))
          load app_path(owner)
        end

        index = run_sequence([
                               lambda do
                                 write_owner.call("    @viewer = 1\n")
                                 if owner_kind == :concern
                                   write_file(base, <<~RUBY)
                                     class #{base_name} < ActionMailer::Base
                                       include #{concern_name}
                                     end
                                   RUBY
                                   load app_path(base)
                                 end
                                 write_file(child, <<~RUBY)
                                   class #{child_name} < #{base_name}
                                     before_action :set_viewer
                                     def digest
                                       mail to: 'reader@example.test'
                                     end
                                   end
                                 RUBY
                                 load app_path(child)
                                 [owner, base, child].uniq
                               end,
                               lambda do
                                 write_owner.call("    @viewer = 1\n    @audit = 2\n")
                                 owner
                               end
                             ])

        mailer = unit_snapshot(index).values.find { |unit| unit['identifier'] == child_name }
        expect(mailer.dig('metadata', 'action_facts', 'digest', 'assigns').map { |fact| fact['ivar'] })
          .to eq(%w[@viewer @audit])
      ensure
        # Fixture mailers and concerns must not join later examples' complete inventories.
        [child_name, base_name, concern_name].compact.each do |name|
          Object.send(:remove_const, name) if Object.const_defined?(name, false)
        end
        [owner, base, child].compact.uniq.each { |relative| FileUtils.rm_f(app_path(relative)) }
        # An empty root created after Rails boot is not managed by Zeitwerk.
        Array(created_directories).reverse_each do |relative|
          directory = app_path(relative)
          Dir.rmdir(directory) if File.directory?(directory) && Dir.empty?(directory)
        end
      end
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
            field :id, String, null: false
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
      reloader = instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true, once_owned?: false)
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

  describe 'unresolvable routes in graph_analysis.json' do
    after do
      created = app_path('app/controllers/lanterns_controller.rb')
      FileUtils.cp(created, File.join(@pristine_root, 'app/controllers/lanterns_controller.rb')) if File.exist?(created)
    end

    def lanterns_source(*actions)
      "class LanternsController < ApplicationController\n" \
        "#{actions.map { |action| "  def #{action}\n    @lanterns = Post.recent\n  end\n" }.join}end\n"
    end

    it 'reports missing controllers and actions, and follows a controller edit that supplies the action' do
      write_file('app/controllers/lanterns_controller.rb', lanterns_source('index'))
      load app_path('app/controllers/lanterns_controller.rb')
      write_file('config/routes.rb', <<~RUBY)
        Rails.application.routes.draw do
          resources :posts, only: %i[index show create]
          resources :lanterns, only: %i[index]
          get 'lanterns/archive', to: 'lanterns#archive'
          get 'ghosts', to: 'ghosts#index'
          get 'welcome', to: 'rails/welcome#index'
        end
      RUBY
      Rails.application.reload_routes!

      ghost = { 'route' => 'GET /ghosts', 'controller' => 'GhostsController',
                'action' => 'index', 'reason' => 'missing_controller' }
      archive = { 'route' => 'GET /lanterns/archive', 'controller' => 'LanternsController',
                  'action' => 'archive', 'reason' => 'missing_action' }
      unresolvable = ->(dir) { read_json(dir, 'graph_analysis.json')['unresolvable_routes'] }

      expect(unresolvable.call(run_sequence([]))).to eq([ghost, archive])

      index_dir = run_sequence([
                                 lambda {
                                   write_file('app/controllers/lanterns_controller.rb',
                                              lanterns_source('index', 'archive'))
                                   load app_path('app/controllers/lanterns_controller.rb')
                                   'app/controllers/lanterns_controller.rb'
                                 }
                               ])
      expect(unresolvable.call(index_dir)).to eq([ghost])
    end

    # Rails serves a routed action with no method by implicit render (#726):
    # the template alone resolves it, and removing the template unresolves it
    # again, through incremental runs that agree with a full one at each step.
    # Its own controller: the sibling example loads an `archive` method into
    # LanternsController, and a class stays loaded for the rest of the process.
    it 'follows a template that serves the action by implicit render' do
      controller = 'app/controllers/beacons_controller.rb'
      write_file(controller, "class BeaconsController < ApplicationController\n  def index\n  end\nend\n")
      load app_path(controller)
      write_file('config/routes.rb', <<~RUBY)
        Rails.application.routes.draw do
          resources :posts, only: %i[index show create]
          resources :beacons, only: %i[index]
          get 'beacons/archive', to: 'beacons#archive'
        end
      RUBY
      Rails.application.reload_routes!
      archive = { 'route' => 'GET /beacons/archive', 'controller' => 'BeaconsController',
                  'action' => 'archive', 'reason' => 'missing_action' }
      unresolvable = ->(dir) { read_json(dir, 'graph_analysis.json')['unresolvable_routes'] }
      template = 'app/views/beacons/archive.html.erb'

      index_dir = run_sequence([-> { write_file(template, "<h1>Archive</h1>\n") }])
      expect(unresolvable.call(index_dir)).to eq([])

      index_dir = run_sequence([-> { write_file(template, "<h1>Archive</h1>\n") }, -> { delete_file(template) }])
      expect(unresolvable.call(index_dir)).to eq([archive])
    ensure
      # The class stays loaded, so its file joins the pristine tree.
      FileUtils.cp(app_path(controller), File.join(@pristine_root, controller)) if File.exist?(app_path(controller))
    end
  end

  describe 'documentation units' do
    def doc_unit(dir, identifier)
      payload = Woods::Generation.new(output_dir: dir).payload_dir
      Dir[File.join(payload, 'docs', '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
        .find { |unit| unit['identifier'] == identifier }
    end

    def edges(dir, identifier)
      doc_unit(dir, identifier).fetch('dependencies').map { |edge| edge.values_at('type', 'target', 'via') }
    end

    def guide(*lines)
      "# Posting guide\n\n#{lines.join("\n")}\n"
    end

    # The per-example reset globs `*`, which skips dot directories.
    after { %w[.claude .github].each { |dir| FileUtils.rm_rf(app_path(dir)) } }

    it 'indexes a document created after the baseline, with its edges and reverse edges' do
      index = run_sequence([
                             lambda {
                               write_file('docs/posting.md', guide('`Post` lives in `app/models/post.rb`.',
                                                                   'Routes: `GET /posts`. Unknown: `Shipment`.',
                                                                   'See [the readme](../README.md).'))
                             },
                             -> { write_file('README.md', "# Dummy\n\nStart with [posting](docs/posting.md).\n") }
                           ])

      expect(edges(index, 'docs/posting.md')).to include(%w[model Post documents], ['route', 'GET /posts', 'documents'],
                                                         %w[doc README.md doc_link])
      expect(edges(index, 'README.md')).to eq([%w[doc docs/posting.md doc_link]])
      mentions = doc_unit(index, 'docs/posting.md').dig('metadata', 'mentions')
      expect(mentions.to_h { |mention| mention.values_at('text', 'resolved') })
        .to include('Post' => true, 'app/models/post.rb' => true, 'GET /posts' => true, 'Shipment' => false)

      graph = JSON.parse(File.read(File.join(Woods::Generation.new(output_dir: index).payload_dir,
                                             'dependency_graph.json')))
      expect(graph.fetch('reverse').fetch('Post')).to include('docs/posting.md')
      expect(graph.fetch('pagerank').values_at('docs/posting.md', 'README.md')).to eq([0.0, 0.0])
    end

    it 'gives an unchanged document its edge when the target appears, and takes it back when it goes' do
      index = run_sequence([
                             -> { write_file('docs/late.md', guide('`LateService` and `rake late:run`.')) },
                             -> { write_file('app/services/late_service.rb', service_source('LateService')) },
                             -> { write_file('lib/tasks/late.rake', rake_source('late', %w[run])) }
                           ])
      expect(edges(index, 'docs/late.md')).to eq([%w[service LateService documents], %w[rake_task late:run documents]])

      delete_file('app/services/late_service.rb')
      delete_file('lib/tasks/late.rake')
      Woods::Extractor.new(output_dir: index)
                      .extract_changed(%w[app/services/late_service.rb lib/tasks/late.rake].map do |path|
                                         app_path(path)
                                       end)

      expect(edges(index, 'docs/late.md')).to eq([])
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'follows an edit, a rename and a deletion, including the documents that link to the file' do
      run_sequence([
                     -> { write_file('docs/a.md', guide('`Post` and [b](b.md).')) },
                     -> { write_file('docs/b.md', guide('`Comment` and [a](a.md).')) },
                     -> { write_file('docs/a.md', guide('No mentions now, still [b](b.md).')) },
                     lambda {
                       move_file('docs/b.md', 'docs/guides/b.md')
                       %w[docs/b.md docs/guides/b.md]
                     },
                     -> { write_file('docs/a.md', guide('Now [b](guides/b.md).')) },
                     -> { delete_file('docs/guides/b.md') },
                     -> { delete_file('docs/a.md') }
                   ])
    end

    it 'follows a route a document names when config/routes.rb changes' do
      index = run_sequence([
                             -> { write_file('docs/api.md', guide('```', 'GET /comments', '```')) },
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

      expect(edges(index, 'docs/api.md')).to eq([['route', 'GET /comments', 'documents']])
    end

    it 'indexes agent instruction files under dot directories' do
      index = run_sequence([
                             -> { write_file('.claude/rules/models.md', guide('`Post` rules.')) },
                             -> { write_file('.claude/skills/review/SKILL.md', guide('`Comment` review.')) },
                             -> { write_file('.github/pull_request_template.md', guide('Checklist.')) },
                             -> { write_file('.claude/rules/models.md', guide('`Comment` rules.')) },
                             -> { delete_file('.claude/skills/review/SKILL.md') }
                           ])

      expect(edges(index, '.claude/rules/models.md')).to eq([%w[model Comment documents]])
      expect(doc_unit(index, '.github/pull_request_template.md')).not_to be_nil
    end

    it 'publishes redacted source and section chunks identically in both modes' do
      secret = "AKIA#{'ABCD1234' * 2}"
      index = run_sequence([
                             lambda {
                               write_file('docs/keys.md', "# Keys\n\nNever commit `#{secret}`.\n\n## Rotation\n\n" \
                                                          "#{'Rotate the ledger key every quarter. ' * 30}\n")
                             }
                           ])
      unit = doc_unit(index, 'docs/keys.md')

      expect(JSON.generate(unit)).not_to include(secret)
      expect(unit.fetch('source_code')).to include('Never commit `[REDACTED]`.')
      expect(unit.fetch('chunks').map { |chunk| chunk.dig('metadata', 'heading') }).to eq(%w[Keys Rotation])
    end

    it 'does not republish when nothing a document names has changed' do
      write_file('docs/steady.md', guide('`Post` and `Shipment`.'))
      index = full_extraction
      manifest = File.join(Woods::Generation.new(output_dir: index).payload_dir, 'manifest.json')
      before = File.read(manifest)

      expect(Woods::Extractor.new(output_dir: index).extract_changed([])).to eq([])
      expect(File.read(File.join(Woods::Generation.new(output_dir: index).payload_dir, 'manifest.json'))).to eq(before)
    end

    it 're-resolves documents on a targeted refresh' do
      write_file('docs/tasks.md', guide('`rake audit:run`'))
      index = full_extraction
      write_file('lib/tasks/audit.rake', rake_source('audit', %w[run]))

      Woods::Extractor.new(output_dir: index).refresh(:rake_tasks)

      expect(edges(index, 'docs/tasks.md')).to eq([%w[rake_task audit:run documents]])
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'keeps one unit for a symlinked document through target edits, alias edits and a deleted alias' do
      index = run_sequence([
                             -> { write_file('AGENTS.md', guide('`Post` rules.')) },
                             lambda {
                               File.symlink('AGENTS.md', app_path('CLAUDE.md'))
                               'CLAUDE.md'
                             },
                             lambda {
                               FileUtils.mkdir_p(app_path('.github'))
                               File.symlink('../AGENTS.md', app_path('.github/copilot-instructions.md'))
                               '.github/copilot-instructions.md'
                             },
                             -> { write_file('AGENTS.md', guide('`Comment` rules.')) },
                             lambda {
                               File.write(app_path('CLAUDE.md'), guide('`Post` and `Comment` rules.'))
                               'CLAUDE.md'
                             },
                             -> { delete_file('CLAUDE.md') }
                           ])

      expect(doc_unit(index, 'AGENTS.md').dig('metadata', 'aliases')).to eq(['.github/copilot-instructions.md'])
      expect(edges(index, 'AGENTS.md')).to eq([%w[model Comment documents], %w[model Post documents]])
      expect(doc_unit(index, 'CLAUDE.md')).to be_nil
    end

    it 'keeps a symlinked document when an alias is deleted without being named' do
      write_file('AGENTS.md', guide('`Post` rules.'))
      File.symlink('AGENTS.md', app_path('CLAUDE.md'))

      index = run_sequence([
                             lambda {
                               delete_file('CLAUDE.md')
                               write_file('app/services/other_service.rb', service_source('OtherService'))
                             }
                           ])

      expect(doc_unit(index, 'AGENTS.md').dig('metadata', 'aliases')).to eq([])
    end

    it 'resolves a path to every file that defines a task, in both modes' do
      index = run_sequence([
                             -> { write_file('lib/tasks/ledger.rake', rake_source('ledger', %w[close])) },
                             -> { write_file('lib/tasks/ledger_more.rake', rake_source('ledger', %w[close])) },
                             -> { write_file('docs/closing.md', guide('Edit `lib/tasks/ledger_more.rake`.')) }
                           ])

      expect(edges(index, 'docs/closing.md')).to eq([%w[rake_task ledger:close documents]])
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

    it 'publishes periodic registrations on a full run and leaves initializer edits to one' do
      periodic = lambda do |*crons|
        lines = crons.map { |cron| "    mgr.register('#{cron}', 'PublishPostJob')\n" }.join
        "Sidekiq.configure_server do |config|\n  config.periodic do |mgr|\n#{lines}  end\nend\n"
      end
      path = write_file('config/initializers/periodic.rb', periodic.call('0 7 * * *', '0 19 * * *'))

      index = full_extraction
      expect(read_json(index, 'dependency_graph.json').fetch('reverse').fetch('PublishPostJob'))
        .to include('scheduled:publish_post_job', 'scheduled:publish_post_job:2')

      write_file(path, periodic.call('0 7 * * *'))
      expect { Woods::Extractor.new(output_dir: index).extract_changed([path]) }
        .to raise_error(Woods::ExtractionError, /fresh Rails process/)
    end

    it 'refreshes Sidekiq schedule entries when config/schedule.yml is edited and deleted' do
      write_file('config/schedule.yml', "publish:\n  cron: '0 7 * * *'\n  class: PublishPostJob\n")
      expect(read_json(full_extraction, 'dependency_graph.json').fetch('reverse').fetch('PublishPostJob'))
        .to include('scheduled:publish')

      run_sequence([
                     lambda {
                       write_file('config/schedule.yml', <<~YAML)
                         publish:
                           every: 45m
                           class: PublishPostJob
                         PublishPostJob:
                           cron: '0 8 * * 0'
                       YAML
                     },
                     -> { delete_file('config/schedule.yml') }
                   ])
    end

    it 'publishes a config/sidekiq.yml schedule on a full run and leaves its edits to one' do
      schedule = lambda do |cron|
        ":scheduler:\n  :schedule:\n    publish:\n      cron: '#{cron}'\n      class: PublishPostJob\n"
      end
      path = write_file('config/sidekiq.yml', schedule.call('0 7 * * *'))

      index = full_extraction
      expect(read_json(index, 'dependency_graph.json').fetch('reverse').fetch('PublishPostJob'))
        .to include('scheduled:publish')

      write_file(path, schedule.call('0 9 * * *'))
      expect { Woods::Extractor.new(output_dir: index).extract_changed([path]) }
        .to raise_error(Woods::ExtractionError, /fresh Rails process/)
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

    it 'leaves the manifest timestamp alone when a Ruby change alters no unit' do
      index_dir = Dir.mktmpdir('woods_diff_ruby_noop')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      before = read_json(index_dir, 'manifest.json')['extracted_at']
      sleep 1.1 # the manifest stamp has second resolution
      FileUtils.touch(app_path('app/models/post.rb'))
      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/models/post.rb'])

      expect(touched).to be_empty
      expect(read_json(index_dir, 'manifest.json')['extracted_at']).to eq(before)
    end

    it 'still publishes when a Ruby change alters a unit' do
      index_dir = Dir.mktmpdir('woods_diff_ruby_change')
      (@scratch_dirs ||= []) << index_dir
      Woods::Extractor.new(output_dir: index_dir).extract_all

      before = read_json(index_dir, 'manifest.json')['extracted_at']
      sleep 1.1 # the manifest stamp has second resolution
      write_file('app/models/post.rb', "#{File.read(app_path('app/models/post.rb'))}# a trailing remark\n")
      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/models/post.rb'])

      expect(touched).to include('Post')
      expect(read_json(index_dir, 'manifest.json')['extracted_at']).not_to eq(before)
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'leaves the manifest timestamp alone when the changed Ruby file belongs to no extractor' do
      write_file('script/ledger_probe.rb', "puts :ledger\n")
      index_dir = full_extraction

      before = read_json(index_dir, 'manifest.json')['extracted_at']
      sleep 1.1 # the manifest stamp has second resolution
      write_file('script/ledger_probe.rb', "# a remark\nputs :ledger\n")
      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed(['script/ledger_probe.rb'])

      expect(touched).to be_empty
      expect(read_json(index_dir, 'manifest.json')['extracted_at']).to eq(before)
    end
  end

  describe 'units re-extracted to the same result' do
    def job_unit(index_dir, identifier)
      Dir[File.join(payload_dir(index_dir), 'jobs', '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path)) }
        .find { |document| document['identifier'] == identifier }
    end

    it 'keeps unrelated hybrid jobs out of the touched set when a model changes' do
      index_dir = full_extraction
      write_file('app/models/comment.rb', "#{File.read(app_path('app/models/comment.rb'))}# a trailing remark\n")

      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed(['app/models/comment.rb'])

      expect(touched).to include('Comment')
      expect(touched).not_to include('PublishPostJob', 'SignatureJob')
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'still refreshes the dependents of a retained job when a new caller appears' do
      index_dir = full_extraction
      caller_path = write_file('app/services/ledger_dispatch_service.rb', <<~RUBY)
        class LedgerDispatchService
          def call(post) = SignatureJob.perform_later(post.id, required: true)
        end
      RUBY

      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed([caller_path])

      expect(touched).not_to include('SignatureJob')
      expect(job_unit(index_dir, 'SignatureJob').fetch('dependents'))
        .to include('type' => 'service', 'identifier' => 'LedgerDispatchService')
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'keeps source-reference edge ownership for a retained job across successive runs' do
      write_file('app/models/ledger_rate.rb', "class LedgerRate\n  def self.for(*) = nil\nend\n")
      job = write_file('app/jobs/ledger_rate_job.rb', <<~RUBY)
        class LedgerRateJob < ActiveJob::Base
          def perform(id) = LedgerRate.for(id)
        end
      RUBY
      load app_path('app/models/ledger_rate.rb')
      load app_path(job)
      index_dir = full_extraction
      added = read_json(index_dir, 'source_references.json').fetch('owners')
                                                            .find { |owner| owner['identifier'] == 'LedgerRateJob' }
      expect(added.fetch('added')).not_to be_empty

      2.times do |round|
        path = write_file("app/services/ledger_round_#{round}_service.rb", service_source("LedgerRound#{round}Service"))
        touched = Woods::Extractor.new(output_dir: index_dir).extract_changed([path])

        expect(touched).not_to include('LedgerRateJob')
        expect(differences(index_dir, full_extraction)).to be_empty
      end
      expect(read_json(index_dir, 'source_references.json').fetch('owners'))
        .to include(added)
    ensure
      %i[LedgerRateJob LedgerRate].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    it 'refreshes git facts for a retained unit whose file was committed without altering it' do
      path = write_file('app/jobs/ledger_idle_job.rb',
                        "class LedgerIdleJob < ActiveJob::Base\n  def perform; end\nend\n")
      load app_path(path)
      git_in_app('init')
      git_in_app('config', 'user.name', 'Woods test')
      git_in_app('config', 'user.email', 'woods-test@example.invalid')
      git_in_app('add', '.')
      git_in_app('commit', '-m', 'baseline')
      index_dir = full_extraction
      expect(job_unit(index_dir, 'LedgerIdleJob').dig('metadata', 'git', 'commit_count')).to eq(1)

      FileUtils.touch(app_path(path))
      expect(Woods::Extractor.new(output_dir: index_dir).extract_changed([path])).to be_empty

      git_in_app('commit', '--allow-empty', '-m', 'unrelated')
      File.chmod(0o755, app_path(path))
      git_in_app('commit', '-am', 'mode only')
      touched = Woods::Extractor.new(output_dir: index_dir).extract_changed([path])

      expect(touched).to eq(['LedgerIdleJob'])
      expect(job_unit(index_dir, 'LedgerIdleJob').dig('metadata', 'git', 'commit_count')).to eq(2)
      expect(differences(index_dir, full_extraction)).to be_empty
    ensure
      FileUtils.rm_rf(app_path('.git'))
      Object.send(:remove_const, :LedgerIdleJob) if Object.const_defined?(:LedgerIdleJob, false)
    end

    def git_in_app(*args)
      output, status = Open3.capture2e('git', '-C', @app_root, *args)
      raise "git #{args.first} failed: #{output}" unless status.success?
    end
  end

  describe 'caller-dependent partials' do
    def navigation_unit(index)
      payload = Woods::Generation.new(output_dir: index).payload_dir
      Dir[File.join(payload, 'view_templates', '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path, encoding: 'UTF-8')) }
        .find { |unit| unit['identifier'] == 'shared/_navigation.html.erb' }
    end

    def render_targets(index)
      navigation_unit(index).fetch('dependencies').select { |dep| dep['via'] == 'render' }.map { |dep| dep['target'] }
    end

    it 'follows the callers of an unchanged partial as pages and partials come and go' do
      navigation = "<%= render 'account_head' %>\n"
      index = run_sequence([
                             -> { write_file('app/views/shared/_navigation.html.erb', navigation) },
                             -> { write_file('app/views/posts/index.html.erb', "<%= render 'shared/navigation' %>\n") },
                             -> { write_file('app/views/posts/_account_head.html.erb', "<p>posts</p>\n") }
                           ])
      expect(render_targets(index)).to eq(['posts/_account_head.html.erb'])

      [
        lambda {
          [write_file('app/views/profiled/index.html.erb', "<%= render 'shared/navigation' %>\n"),
           write_file('app/views/profiled/_account_head.html.erb', "<p>profiled</p>\n")]
        },
        -> { delete_file('app/views/posts/index.html.erb') },
        -> { delete_file('app/views/profiled/_account_head.html.erb') }
      ].each_with_index do |operation, step|
        Woods::Extractor.new(output_dir: index).extract_changed(Array(operation.call))
        found = differences(index, full_extraction)
        expect(found).to be_empty, "diverged after step #{step + 4}:\n  #{found.join("\n  ")}"
      end

      expect(render_targets(index)).to eq([])
      expect(navigation_unit(index).dig('metadata', 'unresolved_partials'))
        .to eq([{ 'kind' => 'caller_prefix', 'name' => 'account_head', 'candidates' => [] }])
    end

    it 'follows a view directory gaining its controller' do
      write_file('app/views/shared/_navigation.html.erb', "<%= render 'account_head' %>\n")
      write_file('app/views/posts/index.html.erb', "<%= render 'shared/navigation' %>\n")
      write_file('app/views/posts/_account_head.html.erb', "<p>posts</p>\n")
      write_file('app/views/ledger_books/index.html.erb', "<%= render 'shared/navigation' %>\n")
      write_file('app/views/ledger_books/_account_head.html.erb', "<p>ledger books</p>\n")

      index = run_sequence([
                             lambda {
                               write_file('app/controllers/ledger_books_controller.rb', <<~RUBY)
                                 class LedgerBooksController < ApplicationController
                                   def index; end
                                 end
                               RUBY
                               load app_path('app/controllers/ledger_books_controller.rb')
                               'app/controllers/ledger_books_controller.rb'
                             }
                           ])

      expect(render_targets(index)).to eq([])
      expect(navigation_unit(index).dig('metadata', 'unresolved_partials', 0, 'candidates'))
        .to eq(%w[ledger_books/_account_head.html.erb posts/_account_head.html.erb])
    end

    # The controller stays loaded for the rest of the process, so its file
    # joins the pristine tree and the runtime keeps agreeing with the tree.
    after do
      controller = app_path('app/controllers/ledger_books_controller.rb')
      next unless File.exist?(controller)

      FileUtils.cp(controller, File.join(@pristine_root, 'app/controllers/ledger_books_controller.rb'))
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

      graph = read_json(index_dir, 'dependency_graph.json')
      expect(graph.fetch('reverse').fetch('http_api')).to include('FirstHttpService', 'SecondHttpService')
      expect(graph.fetch('edges').fetch('FirstHttpService'))
        .to include('target' => 'http_api', 'via' => 'external_call')
      expect(graph.fetch('edges').fetch('FirstHttpService').map { |edge| edge['via'] }).not_to include('code_reference')
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

  describe 'component render targets' do
    let(:render_target_files) do
      %w[
        app/components/rt_parts.rb
        app/components/rt_parts/chip.rb
        app/components/rt_shelf/page_component.rb
        app/components/rt_shelf/row_component.rb
        app/components/rt_desk/card_component.rb
        app/controllers/rt_desk_controller.rb
        app/controllers/rt_lamp_controller.rb
        app/components/rt_lamp/shade_component.rb
      ]
    end

    def write_and_load(relative, source)
      write_file(relative, source)
      load app_path(relative)
      relative
    end

    def render_edges(index, identifier)
      unit = unit_snapshot(index).values.find { |candidate| candidate['identifier'] == identifier }
      [unit['dependencies'].select { |dep| dep['via'] == 'render' }.map { |dep| dep['target'] },
       unit.dig('metadata', 'unresolved_renders').map { |entry| entry['name'] }]
    end

    # The classes stay in ApplicationComponent.descendants for the rest of the
    # process, as `Tag` does above, so the files join the pristine tree.
    after do
      render_target_files.each do |relative|
        next unless File.exist?(app_path(relative))

        FileUtils.mkdir_p(File.dirname(File.join(@pristine_root, relative)))
        FileUtils.cp(app_path(relative), File.join(@pristine_root, relative))
      end
    end

    it 'retargets an unchanged renderer when its sibling and its Kit constant are created' do
      index = run_sequence([
                             lambda do
                               [write_and_load('app/components/rt_parts.rb', "module RtParts\nend\n"),
                                write_and_load('app/components/rt_shelf/page_component.rb', <<~RUBY)]
                                  module RtShelf
                                    class PageComponent < ApplicationComponent
                                      include RtParts

                                      def call
                                        render RowComponent.new
                                        Chip("a")
                                        render partial("x")
                                      end
                                    end
                                  end
                                RUBY
                             end,
                             lambda do
                               write_and_load('app/components/rt_shelf/row_component.rb', <<~RUBY)
                                 module RtShelf
                                   class RowComponent < ApplicationComponent
                                     def call = "row"
                                   end
                                 end
                               RUBY
                             end,
                             lambda do
                               [write_and_load('app/components/rt_parts/chip.rb', <<~RUBY),
                                 module RtParts
                                   class Chip < ApplicationComponent
                                     def call = "chip"
                                   end
                                 end
                               RUBY
                                write_and_load('app/components/rt_parts.rb', <<~RUBY)]
                                  module RtParts
                                    def Chip(*args) = RtParts::Chip.new(*args).call
                                  end
                                RUBY
                             end
                           ])

      expect(render_edges(index, 'RtShelf::PageComponent')).to eq([%w[RtParts::Chip RtShelf::RowComponent], []])
    end

    it 'retargets an unchanged controller when the component it renders is created' do
      index = run_sequence([
                             lambda do
                               write_and_load('app/controllers/rt_desk_controller.rb', <<~RUBY)
                                 class RtDeskController < ApplicationController
                                   def show
                                     render RtDesk::CardComponent.new
                                   end
                                 end
                               RUBY
                             end,
                             lambda do
                               write_and_load('app/components/rt_desk/card_component.rb', <<~RUBY)
                                 module RtDesk
                                   class CardComponent < ApplicationComponent
                                     def call = "card"
                                   end
                                 end
                               RUBY
                             end
                           ])

      expect(render_edges(index, 'RtDeskController')).to eq([%w[RtDesk::CardComponent], []])
    end

    it 'summarises unresolved renders and action facts on the graph node, full and incremental alike (#837)' do
      node = ->(index) { read_json(index, 'dependency_graph.json').fetch('nodes').fetch('RtLampController') }
      index = run_sequence([
                             lambda do
                               write_and_load('app/controllers/rt_lamp_controller.rb', <<~RUBY)
                                 class RtLampController < ApplicationController
                                   def show
                                     render RtLamp::ShadeComponent.new
                                   end
                                 end
                               RUBY
                             end
                           ])
      expect(node.call(index)).to include('unresolved_render_count' => 1, 'fact_actions' => ['show'])
      expect(read_json(index, 'dependency_graph.json').fetch('node_facts'))
        .to eq(%w[fact_actions unresolved_render_count])

      component = write_and_load('app/components/rt_lamp/shade_component.rb', <<~RUBY)
        module RtLamp
          class ShadeComponent < ApplicationComponent
            def call = "shade"
          end
        end
      RUBY
      Woods::Extractor.new(output_dir: index).extract_changed([component])
      expect(node.call(index)).not_to have_key('unresolved_render_count')
      expect(differences(index, full_extraction)).to be_empty
    end
  end

  it 'keeps an unrelated locale edit out of hybrid family extraction' do
    path = 'config/locales/hybrid_control.yml'
    index = full_extraction
    write_file(path, "en:\n  hybrid_control: independent edit\n")
    expect_any_instance_of(Woods::Extractors::JobExtractor).not_to receive(:extract_all)
    expect_any_instance_of(Woods::Extractors::SerializerExtractor).not_to receive(:extract_all)
    expect_any_instance_of(Woods::Extractors::PhlexExtractor).not_to receive(:extract_all)
    expect_any_instance_of(Woods::Extractors::ViewComponentExtractor).not_to receive(:extract_all)

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

  it 'keeps inline namespace siblings and their source references distinct in every extraction mode' do
    require 'woods/mcp/index_reader'
    caller_path = write_file('app/models/inline_gateway_caller.rb', <<~RUBY)
      class InlineGatewayCaller
        def call; [InlineGateway::Refundable.call, InlineGateway::Chargeable.call]; end
      end
    RUBY
    paths = %w[Refundable Chargeable].to_h do |name|
      path = write_file("lib/inline_gateway/#{name.underscore}.rb",
                        "module InlineGateway; module #{name}; def self.call; :full; end; end; end")
      load app_path(path)
      [name, path]
    end
    load app_path(caller_path)
    index = full_extraction
    reader = Woods::MCP::IndexReader.new(index)
    writer = Woods::Extractor.new(output_dir: index)

    %i[full incremental refresh].each do |mode|
      unless mode == :full
        paths.each do |name, path|
          write_file(path, "module InlineGateway; module #{name}; def self.call; :#{mode}; end; end; end")
          load app_path(path)
        end
        mode == :incremental ? writer.extract_changed(paths.values) : writer.refresh(:libs)
        writer.raise_on_publication_failure!
      end
      expect(reader.find_unit('InlineGateway', type: 'lib')).to be_nil
      paths.each_key do |name|
        identifier = "InlineGateway::#{name}"
        expect(reader.find_unit(identifier, type: 'lib').fetch('source_code')).to include(":#{mode}")
        expect(reader.find_unit('InlineGatewayCaller', type: 'poro').fetch('dependencies')).to include(
          'type' => 'lib', 'target' => identifier, 'via' => 'code_reference'
        )
      end
      expect(differences(index, full_extraction)).to be_empty
    end
  ensure
    %i[InlineGateway InlineGatewayCaller].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  describe 'unclaimed Ruby under app/ (#672, #673)' do
    after do
      %i[SweepDateHelper SweepBillingView SweepConstraint SweepSlugifier SweepTailwind SweepNamespace
         SweepMapper SweepPattern SweepSerializerHelpers SweepFormatter SweepVersionCapabilities
         SweepFlipService].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    def write_and_load(relative, source)
      write_file(relative, source)
      load app_path(relative)
      relative
    end

    def sweep_units(index, marker: 'unclaimed_sweep')
      unit_snapshot(index).values.select { |unit| unit.dig('metadata', 'discovered_via') == marker }
                          .map { |unit| unit['identifier'] }
    end

    it 'adds, edits, and prunes swept files equivalently to a full extraction' do
      run_sequence([
                     lambda do
                       write_and_load('app/helpers/sweep_date_helper.rb', <<~RUBY)
                         module SweepDateHelper
                           def pretty_date(value) = value.to_s
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load('app/view_models/sweep_billing_view.rb', <<~RUBY)
                         class SweepBillingView < SimpleDelegator
                           def total_label = SweepDateHelper.name
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load('app/constraints/sweep_constraint.rb', <<~RUBY)
                         class SweepConstraint
                           def self.matches?(_request) = true
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load('app/lib/sweep_slugifier.rb', "class SweepSlugifier\n  def call(t) = t\nend\n")
                     end,
                     lambda do
                       write_and_load('app/views/ui/sweep_tailwind.rb', <<~RUBY)
                         module SweepTailwind
                           def tw(*classes) = classes.join(' ')
                         end
                       RUBY
                     end,
                     -> { write_and_load('app/models/sweep_namespace.rb', "module SweepNamespace\nend\n") },
                     lambda do
                       write_and_load('app/models/sweep_namespace.rb', <<~RUBY)
                         module SweepNamespace
                           LIMIT = 3
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load('app/view_models/sweep_billing_view.rb', <<~RUBY)
                         class SweepBillingView < SimpleDelegator
                           def total_label = SweepSlugifier.new.call('total')
                         end
                       RUBY
                     end,
                     -> { write_and_load('app/models/sweep_pattern.rb', "SweepPattern = /\A\w+\z/\n") },
                     lambda do
                       Object.send(:remove_const, :SweepPattern)
                       write_and_load('app/models/sweep_pattern.rb', "SweepPattern = %w[a b].freeze\n")
                     end,
                     -> { delete_file('app/constraints/sweep_constraint.rb') }
                   ])
    end

    it 'falls back to the PORO path where an owning extractor emits nothing, in both modes' do
      helpers = 'app/serializers/sweep_serializer_helpers.rb'
      run_sequence([
                     lambda do
                       write_and_load(helpers, <<~RUBY)
                         module SweepSerializerHelpers
                           def money(value) = value.to_s
                         end
                         class SweepFormatter
                           def call(value) = value
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load('app/graphql/sweep_version_capabilities.rb', <<~RUBY)
                         module SweepVersionCapabilities
                           def self.supports?(capability, version) = true
                         end
                       RUBY
                     end,
                     lambda do
                       write_and_load(helpers, <<~RUBY)
                         module SweepSerializerHelpers
                           def money(value) = value.to_s
                           def percent(value) = "\#{value}%"
                         end
                         class SweepFormatter
                           def call(value) = value
                         end
                       RUBY
                     end,
                     -> { delete_file(helpers) }
                   ])
      index = full_extraction
      expect(sweep_units(index, marker: 'owner_fallback')).to eq(['SweepVersionCapabilities'])
    end

    it 'moves a file between its owner and the fallback as its shape changes' do
      flip = 'app/services/sweep_flip_service.rb'
      service = "class SweepFlipService\n  def call = :ok\nend\n"
      helper = "module SweepFlipService\n  module_function\n  def call = :ok\nend\n"
      swap = lambda do |source|
        Object.send(:remove_const, :SweepFlipService) if Object.const_defined?(:SweepFlipService, false)
        write_and_load(flip, source)
      end
      run_sequence([-> { swap.call(service) }, -> { swap.call(helper) }, -> { swap.call(service) },
                    -> { swap.call(helper) }])
      expect(sweep_units(full_extraction, marker: 'owner_fallback')).to eq(['SweepFlipService'])
    end

    describe 'a class whose family changes through another file' do
      before do
        stub_const('Sidekiq::Job', Module.new) unless defined?(Sidekiq::Job)
        write_and_load('app/models/sweep_parent.rb', "class SweepParent\n  def base = 1\nend\n")
        write_and_load('app/models/sweep_child.rb', "class SweepChild < SweepParent\n  def perform = 1\nend\n")
      end

      after do
        %i[SweepChild SweepParent].each do |name|
          Object.send(:remove_const, name) if Object.const_defined?(name, false)
        end
      end

      it 'drops the stale poro unit when a parent gains a job mixin outside the blast radius' do
        index = full_extraction
        expect(unit_snapshot(index).values.map { |unit| unit['identifier'] }).to include('SweepChild')

        hook = write_and_load('app/lib/sweep_parent_job.rb', "SweepParent.include(Sidekiq::Job)\n")
        Woods::Extractor.new(output_dir: index).extract_changed([hook])

        expect(unit_snapshot(index).values.select do |unit|
          unit['identifier'] == 'SweepChild' && unit['type'] == 'poro'
        end)
          .to be_empty
        expect(differences(index, full_extraction)).to be_empty
      end

      it 'restores the poro unit after a reload drops the job mixin' do
        hook = write_and_load('app/lib/sweep_parent_job.rb', "SweepParent.include(Sidekiq::Job)\n")
        index = full_extraction

        %i[SweepChild SweepParent].each { |name| Object.send(:remove_const, name) }
        delete_file(hook)
        load app_path('app/models/sweep_parent.rb')
        load app_path('app/models/sweep_child.rb')
        Woods::Extractor.new(output_dir: index).extract_changed([hook])

        expect(differences(index, full_extraction)).to be_empty
        expect(unit_snapshot(index).values.map { |unit| unit['identifier'] }).to include('SweepChild')
      end
    end

    it 'keeps a module nested in a compact-named controller, and the action it prepends' do
      write_and_load('app/controllers/sweep.rb', "module Sweep\nend\n")
      write_and_load('app/controllers/sweep/confirmations_controller.rb', <<~RUBY)
        class Sweep::ConfirmationsController < ApplicationController
          module Behavior
            def new = head(:ok)
          end
          prepend Behavior
        end
      RUBY
      routes = File.read(app_path('config/routes.rb'))
      write_file('config/routes.rb',
                 routes.sub(/^end\s*\z/, "  namespace(:sweep) { resources :confirmations, only: :new }\nend\n"))
      Rails.application.reload_routes!

      index = full_extraction
      units = unit_snapshot(index).values
      behavior = units.find { |unit| unit['identifier'] == 'Sweep::ConfirmationsController::Behavior' }
      expect(behavior).to include('type' => 'poro')
      controller = units.find { |unit| unit['identifier'] == 'Sweep::ConfirmationsController' }
      source = controller.dig('metadata', 'action_sources', 'new')
      expect(source).to include('owner' => 'Sweep::ConfirmationsController::Behavior')
      expect(units.map { |unit| unit['identifier'] }).to include(source.fetch('defined_in'))
    ensure
      Object.send(:remove_const, :Sweep) if Object.const_defined?(:Sweep, false)
    end

    # W-7 (woods#757): an action's facts include the assigns of the filters
    # that run before it, read from the file that defines each filter. Editing
    # only the parent's file must refresh the child's facts.
    it 'refreshes per-action facts when only a parent filter body changes' do
      base = 'app/controllers/sweep_facts_base_controller.rb'
      child = 'app/controllers/sweep_facts_controller.rb'
      parent_source = lambda do |body|
        "class SweepFactsBaseController < ApplicationController\n  private\n\n  def set_viewer\n#{body}  end\nend\n"
      end
      index = run_sequence([
                             lambda do
                               write_and_load(base, parent_source.call("    @viewer = 1\n"))
                               write_and_load(child, <<~RUBY)
                                 class SweepFactsController < SweepFactsBaseController
                                   before_action :set_viewer, only: :show

                                   def show
                                     @post = Post.first
                                   end
                                 end
                               RUBY
                               [base, child]
                             end,
                             -> { write_and_load(base, parent_source.call("    @viewer = 1\n    @audit = 2\n")) }
                           ])

      controller = unit_snapshot(index).values.find { |unit| unit['identifier'] == 'SweepFactsController' }
      facts = controller.dig('metadata', 'action_facts', 'show')
      expect(facts['assigns'].map { |a| [a['ivar'], a['method']] })
        .to eq([%w[@viewer set_viewer], %w[@audit set_viewer], %w[@post show]])
    ensure
      # The classes stay loaded for the rest of the process, so their files join the pristine tree.
      [base, child].each do |relative|
        next unless relative && File.exist?(app_path(relative))

        FileUtils.cp(app_path(relative), File.join(@pristine_root, relative))
      end
    end

    it 'publishes skip-reason changes that touch no unit, and only those' do
      index = full_extraction
      empty = 'app/models/sweep_empty.rb'
      skipped = -> { read_json(index, 'skipped_files.json').fetch('files') }
      quiet_run = -> { Woods::Extractor.new(output_dir: index).extract_changed(['README.md']) }

      write_file(empty, "module SweepEmpty\nend\n")
      quiet_run.call
      expect(skipped.call).to include('path' => empty, 'reason' => 'namespace_only')
      expect(differences(index, full_extraction)).to be_empty

      write_file(empty, "module SweepEmpty\n  def broken(\nend\n")
      quiet_run.call
      expect(skipped.call).to include('path' => empty, 'reason' => 'parse_error')

      stamp = read_json(index, 'manifest.json')['extracted_at']
      sleep 1.1 # the manifest stamp has second resolution
      quiet_run.call
      expect(read_json(index, 'manifest.json')['extracted_at']).to eq(stamp)

      delete_file(empty)
      quiet_run.call
      expect(skipped.call.map { |entry| entry['path'] }).not_to include(empty)
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'parses each PORO source once per full extraction' do
      write_and_load('app/helpers/sweep_date_helper.rb', "module SweepDateHelper\n  def d = 1\nend\n")
      parses = Hash.new(0)
      collector = Woods::SourceReferences::Collector
      allow_any_instance_of(collector).to receive(:call).and_wrap_original do |original, source|
        parses[source] += 1
        original.call(source)
      end
      index = full_extraction
      poro_sources = unit_snapshot(index).values.select { |unit| unit['type'] == 'poro' }
                                         .map { |unit| File.read(app_path(unit['file_path'])) }.uniq
      expect(poro_sources).not_to be_empty
      expect(poro_sources.to_h { |source| [source[0, 40], parses[source]] }.values.uniq).to eq([1])
    end

    it 'publishes swept units and a nested class from a namespace file in a full extraction' do
      write_and_load('app/helpers/sweep_date_helper.rb', "module SweepDateHelper\n  def d = 1\nend\n")
      write_and_load('app/lib/sweep_mapper.rb', <<~RUBY)
        module SweepMapper
          class Base
            def initialize(path) = @path = path
          end
        end
      RUBY
      write_and_load('app/views/ui/sweep_tailwind.rb', "module SweepTailwind\n  def tw = 1\nend\n")
      write_and_load('app/models/sweep_namespace.rb', "module SweepNamespace\n  LIMIT = 3\nend\n")
      index = full_extraction
      expect(sweep_units(index)).to include('SweepDateHelper', 'SweepMapper::Base', 'SweepTailwind')
      write_file('app/models/sweep_empty.rb', "module SweepEmpty\nend\n")
      index = full_extraction
      expect(read_json(index, 'skipped_files.json').fetch('files'))
        .to include('path' => 'app/models/sweep_empty.rb', 'reason' => 'namespace_only')
      namespace = unit_snapshot(index).values.find { |unit| unit['identifier'] == 'SweepNamespace' }
      expect(namespace.fetch('metadata')).to include('ruby_kind' => 'module', 'constants' => ['LIMIT'])
      expect(sweep_units(index)).not_to include('SweepMapper', 'ApplicationController', 'PostsController')
    end
  end

  describe 'configuration sources (#678)' do
    def unit_of(index, type, identifier)
      unit_snapshot(index).values.find { |unit| unit['type'] == type && unit['identifier'] == identifier }
    end

    def reverse_edges(index, identifier)
      read_json(index, 'dependency_graph.json').fetch('reverse').fetch(identifier, [])
    end

    it 'adds, edits and prunes YAML config files equivalently to a full extraction' do
      index = run_sequence([
                             -> { write_file('config/namespaces.yml', "payments:\n  api_host: ledger.example\n") },
                             -> { write_file('app/data/surveys/nps.yml', "title: Score\nquestions:\n  - id: q1\n") },
                             lambda {
                               write_file('config/namespaces.yml', <<~YAML)
                                 default: &default
                                   payments:
                                     api_host: <%= ENV["LEDGER_HOST"] %>
                                 production:
                                   <<: *default
                               YAML
                             },
                             -> { delete_file('app/data/surveys/nps.yml') }
                           ])

      settings = unit_of(index, 'config_file', 'config/namespaces.yml')
      expect(settings.dig('metadata', 'environments')).to eq(%w[production])
      expect(settings.dig('metadata', 'env_vars')).to eq(%w[LEDGER_HOST])
      expect(unit_of(index, 'config_file', 'app/data/surveys/nps.yml')).to be_nil
    end

    it 'never indexes a secret-bearing file, whichever path names it' do
      incremental = run_sequence([
                                   -> { write_file('config/secrets.yml', "token: plaintext-marker\n") },
                                   -> { write_file('config/ledger/api_tokens.yml', "token: plaintext-marker\n") },
                                   -> { write_file('config/widgets.yml', "password: plaintext-marker\n") }
                                 ])
      write_file('config/credentials/production.yml', "token: plaintext-marker\n")

      [incremental, full_extraction].each do |index|
        config_files = unit_snapshot(index).values.select { |unit| unit['type'] == 'config_file' }
        expect(config_files.map { |unit| unit['identifier'] })
          .to eq(%w[config/database.yml config/recurring.yml config/widgets.yml])
        payload = Woods::Generation.new(output_dir: index).payload_dir
        published = Dir.glob(File.join(payload, '**', '*')).select { |path| File.file?(path) }
        expect(published.select { |path| File.read(path).include?('plaintext-marker') }).to eq([])
      end
    end

    it 'links readers to a config file that appears after them, and unlinks when a reader stops reading' do
      Woods.configuration.settings_readers = [{ constant: 'LedgerSettings', file: 'config/ledger.yml' }]
      reader = lambda do |body|
        write_file('app/services/ledger_rate_service.rb',
                   "class LedgerRateService\n  def call\n    #{body}\n  end\nend\n")
      end

      index = run_sequence([
                             -> { reader.call('Rails.application.config_for(:rates)') },
                             -> { write_file('config/rates.yml', "standard: 5\n") },
                             lambda {
                               reader.call('LedgerSettings.rates.standard + Rails.application.config_for(:rates)[:x]')
                             },
                             -> { write_file('config/ledger.yml', "rates:\n  standard: 5\n") },
                             -> { reader.call('YAML.load_file(Rails.root.join("config/ledger.yml"))') },
                             -> { delete_file('config/rates.yml') }
                           ])

      expect(reverse_edges(index, 'config/ledger.yml')).to eq(%w[LedgerRateService])
      expect(unit_of(index, 'service', 'LedgerRateService').fetch('dependencies'))
        .to include('type' => 'config_file', 'target' => 'config/ledger.yml', 'via' => 'reads_config')
      expect(unit_of(index, 'config_file', 'config/ledger.yml').fetch('dependents'))
        .to include(a_hash_including('identifier' => 'LedgerRateService'))
    ensure
      Woods.configuration.settings_readers = []
    end

    it 'links class-based units to the config files they read' do
      with_reader = lambda do |relative|
        source = File.read(app_path(relative))
        cut = source.rindex('end')
        "#{source[0...cut]}\n  def woods_rates = Rails.application.config_for(:rates)\nend\n"
      end

      index = run_sequence([
                             -> { write_file('config/rates.yml', "standard: 5\n") },
                             -> { write_file('app/models/comment.rb', with_reader.call('app/models/comment.rb')) },
                             lambda {
                               write_file('app/controllers/posts_controller.rb',
                                          with_reader.call('app/controllers/posts_controller.rb'))
                             }
                           ])

      expect(reverse_edges(index, 'config/rates.yml')).to eq(%w[Comment PostsController])
    end

    it 'adds, edits and prunes boot, seed and root files equivalently to a full extraction' do
      index = run_sequence([
                             -> { write_file('db/seeds.rb', "Post.create!(title: 'seed')\n") },
                             -> { write_file('db/seeds/comments.rb', "Comment.create!(body: 'seed')\n") },
                             -> { write_file('config/deploy/production.rb', "server 'ledger.example'\n") },
                             -> { write_file('config/importmap.rb', "pin 'application'\n") },
                             -> { write_file('db/seeds.rb', "Comment.create!(body: 'seed')\n") },
                             -> { delete_file('config/deploy/production.rb') }
                           ])

      expect(unit_of(index, 'configuration', 'db/seeds.rb').dig('metadata', 'config_type')).to eq('seeds')
      expect(unit_of(index, 'configuration', 'importmap.rb').dig('metadata', 'config_type')).to eq('importmap')
      expect(reverse_edges(index, 'Comment')).to include('db/seeds.rb', 'db/seeds/comments.rb')
      expect(unit_of(index, 'configuration', 'deploy/production.rb')).to be_nil
    end

    it 'names external services from the Gemfile and follows calls to them through code edits (#814)' do
      write_file('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\ngem 'stripe'\n")
      path = write_file('app/services/charge_service.rb', service_source('ChargeService'))

      index = full_extraction
      expect(unit_of(index, 'configuration', 'Gemfile').dig('metadata', 'external_services'))
        .to eq([{ 'name' => 'Stripe', 'category' => 'payments', 'gems' => ['stripe'] }])
      expect(reverse_edges(index, 'Stripe')).to be_empty

      write_file(path, "class ChargeService\n  def call = Stripe::Charge.create(amount: 1)\nend\n")
      Woods::Extractor.new(output_dir: index).extract_changed([path])
      expect(reverse_edges(index, 'Stripe')).to include('ChargeService')
      expect(differences(index, full_extraction)).to be_empty

      write_file(path, service_source('ChargeService'))
      Woods::Extractor.new(output_dir: index).extract_changed([path])
      expect(reverse_edges(index, 'Stripe')).to be_empty
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'publishes the Gemfile, Rakefile and boot files on a full run and leaves their edits to one' do
      write_file('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\n")
      write_file('Rakefile', "require_relative 'config/application'\n")
      write_file('config/boot.rb', "require 'bundler/setup'\n")

      index = full_extraction
      expect(unit_of(index, 'configuration', 'Gemfile').dig('metadata', 'gem_references')).to eq(%w[rails])
      expect(unit_of(index, 'configuration', 'Rakefile').dig('metadata', 'config_type')).to eq('rakefile')
      expect(unit_of(index, 'configuration', 'boot.rb').dig('metadata', 'config_type')).to eq('boot')

      path = write_file('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\ngem 'sidekiq'\n")
      expect { Woods::Extractor.new(output_dir: index).extract_changed([path]) }
        .to raise_error(Woods::ExtractionError, /fresh Rails process/)
    end

    it 'publishes boot-captured YAML on a full run and leaves its edits to one' do
      path = write_file('config/settings.yml', "payments:\n  api_host: ledger.example\n")

      index = full_extraction
      expect(unit_of(index, 'config_file', 'config/settings.yml').dig('metadata', 'key_paths'))
        .to eq(%w[payments payments.api_host])

      write_file(path, "payments:\n  api_host: other.example\n")
      expect { Woods::Extractor.new(output_dir: index).extract_changed([path]) }
        .to raise_error(Woods::ExtractionError, /fresh Rails process/)
    end

    it 'indexes generators and reports their templates as skipped, through edits and removal' do
      generator = lambda do |body|
        write_file('lib/generators/widget/widget_generator.rb',
                   "class WidgetGenerator < Rails::Generators::NamedBase\n  def #{body}; end\nend\n")
      end
      template = 'lib/generators/widget/templates/widget.rb'

      index = run_sequence([
                             -> { generator.call('create_widget') },
                             -> { write_file(template, "class <%= class_name %> < ApplicationRecord\nend\n") },
                             -> { generator.call('create_widget_file') },
                             -> { write_file(template, "class <%= class_name %>\nend\n") }
                           ])

      expect(unit_of(index, 'lib', 'WidgetGenerator').dig('metadata', 'kind')).to eq('generator')
      expect(read_json(index, 'skipped_files.json').fetch('files'))
        .to include('path' => template, 'reason' => 'template')

      Woods::Extractor.new(output_dir: index).extract_changed(
        [delete_file(template), delete_file('lib/generators/widget/widget_generator.rb')]
      )
      expect(differences(index, full_extraction)).to be_empty
      expect(unit_of(index, 'lib', 'WidgetGenerator')).to be_nil
    end

    describe 'route files' do
      # `draw(:name)` for config/routes/*.rb arrived in Rails 6.1.
      before do
        skip 'draw files need Rails 6.1' unless ActionDispatch::Routing::Mapper.method_defined?(:draw)
      end

      around do |example|
        mapper = ActionDispatch::Routing::Mapper
        next example.run unless mapper.respond_to?(:route_source_locations)

        previous = mapper.route_source_locations
        mapper.route_source_locations = true
        begin
          example.run
        ensure
          mapper.route_source_locations = previous
        end
      end

      # Rails 7.1+ records where a route was drawn; older runtimes expose nothing.
      def runtime_locates_routes?
        ActionDispatch::Journey::Route.method_defined?(:source_location)
      end

      def draw(main, drawn = nil)
        write_file('config/routes.rb', "Rails.application.routes.draw do\n#{main}end\n")
        drawn ? write_file('config/routes/admin.rb', drawn) : delete_file('config/routes/admin.rb')
        Rails.application.reload_routes!
        %w[config/routes.rb config/routes/admin.rb]
      end

      it 'tracks draw files, their routes and route lines through edits and removal' do
        index = run_sequence([
                               lambda {
                                 draw("  resources :posts, only: %i[index show]\n  draw(:admin)\n",
                                      "resources :comments, only: [:index]\n")
                               },
                               lambda {
                                 draw("  resources :posts, only: %i[index show]\n  draw(:admin)\n",
                                      "# moved down a line\nresources :comments, only: %i[index show]\n")
                               },
                               -> { draw("\n  resources :posts, only: %i[index]\n") }
                             ])

        expect(unit_of(index, 'route_file', 'config/routes/admin.rb')).to be_nil
        root_file = unit_of(index, 'route_file', 'config/routes.rb')
        expect(root_file.dig('metadata',
                             'declarations')).to eq([{ 'line' => 3, 'method' => 'resources', 'argument' => 'posts' }])
        route = unit_of(index, 'route', 'GET /posts')
        expect(root_file.dig('metadata', 'source_locations')).to eq(runtime_locates_routes?)
        if runtime_locates_routes?
          expect(route.fetch('file_path')).to eq('config/routes.rb')
          expect(route.dig('metadata', 'line_number')).to eq(3)
          expect(root_file.dig('metadata', 'routes')).to eq(['GET /posts'])
          expect(reverse_edges(index, 'config/routes.rb')).to include('GET /posts')
        else
          expect(route['file_path']).to be_nil
        end
      end

      it 'locates routes in a draw file while it exists' do
        draw("  draw(:admin)\n", "resources :comments, only: [:index]\n")
        index = full_extraction

        admin = unit_of(index, 'route_file', 'config/routes/admin.rb')
        expect(admin.dig('metadata', 'declarations').map { |entry| entry['method'] }).to eq(%w[resources])
        expect(unit_of(index, 'route_file', 'config/routes.rb').fetch('dependencies'))
          .to include('type' => 'route_file', 'target' => 'config/routes/admin.rb', 'via' => 'draw')
        expect(admin.dig('metadata', 'source_locations')).to eq(runtime_locates_routes?)
        next unless runtime_locates_routes?

        expect(admin.dig('metadata', 'routes')).to eq(['GET /comments'])
        expect(unit_of(index, 'route', 'GET /comments').fetch('file_path')).to eq('config/routes/admin.rb')
      end
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

  it 'discovers a new markerless descendant of an application serializer base' do
    base = write_file('app/serializers/ledger_base_serializer.rb', <<~RUBY)
      class LedgerBaseSerializer
        def as_json(*) = { processor: processor }
      end
    RUBY
    load app_path(base)
    index = full_extraction
    view = write_file('app/serializers/ledger_cash_view.rb', <<~RUBY)
      class LedgerCashView < LedgerBaseSerializer
        def processor = 'cash'
      end
    RUBY
    load app_path(view)

    touched = Woods::Extractor.new(output_dir: index).extract_changed([view])

    expect(touched).to include('LedgerCashView')
    expect(differences(index, full_extraction)).to be_empty
  ensure
    %i[LedgerCashView LedgerBaseSerializer].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end

  describe 'markerless job leaves admitted by runtime ancestry' do
    after do
      %i[LedgerCashJob LedgerBaseJob LedgerIconWorker LedgerProbeWorker LedgerImportManager LedgerRate
         Sidekiq].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    def add_leaf_incrementally(base_path, base_source, leaf_path, leaf_source)
      load app_path(write_file(base_path, base_source))
      index = full_extraction
      load app_path(write_file(leaf_path, leaf_source))
      [index, Woods::Extractor.new(output_dir: index).extract_changed([leaf_path])]
    end

    it 'discovers a new leaf of an application ActiveJob base' do
      index, touched = add_leaf_incrementally(
        'app/jobs/ledger_base_job.rb', "class LedgerBaseJob < ActiveJob::Base\n  def perform(id) = id\nend\n",
        'app/jobs/ledger_cash_job.rb', "class LedgerCashJob < LedgerBaseJob\n  def self.ledger = :cash\nend\n"
      )

      expect(touched).to include('LedgerCashJob')
      expect(differences(index, full_extraction)).to be_empty
    end

    def load_sidekiq_stand_in
      Dir.mktmpdir('sidekiq-stand-in') do |gem_root|
        stand_in = File.join(gem_root, 'sidekiq.rb')
        File.write(stand_in, "module Sidekiq\n  module Job; end\n  Worker = Job\nend\n")
        load stand_in
      end
    end

    it 'makes a worker that is the primary class of an app/models file one job unit with its references' do
      load_sidekiq_stand_in
      load app_path(write_file('app/models/ledger_rate.rb', "class LedgerRate\n  def self.for(*) = nil\nend\n"))
      index = full_extraction
      path = write_file('app/models/ledger_import_manager.rb', <<~RUBY)
        class LedgerImportManager
          include Sidekiq::Worker
          def perform(id) = LedgerRate.for(Post.find(id), SignatureService)
        end
      RUBY
      load app_path(path)

      Woods::Extractor.new(output_dir: index).extract_changed([path])

      payload = Woods::Generation.new(output_dir: index).payload_dir
      graph = Woods::DependencyGraph.from_h(JSON.parse(File.read(File.join(payload, 'dependency_graph.json'))))
      expect(graph.node_types('LedgerImportManager')).to eq([:job])
      expect(graph.dependencies_of('LedgerImportManager', type: :job))
        .to include('LedgerRate', 'Post', 'SignatureService')
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'discovers a new leaf of a Sidekiq worker' do
      load_sidekiq_stand_in
      index, touched = add_leaf_incrementally(
        'app/workers/ledger_probe_worker.rb',
        "class LedgerProbeWorker\n  include Sidekiq::Worker\n  def perform(id) = id\nend\n",
        'app/workers/ledger_icon_worker.rb',
        "class LedgerIconWorker < LedgerProbeWorker\n  def self.icon = :ledger\nend\n"
      )

      expect(touched).to include('LedgerIconWorker')
      expect(differences(index, full_extraction)).to be_empty
    end
  end

  describe 'generated job classes' do
    after do
      %i[LedgerWidget LedgerAsync LedgerSyncCaller].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end

    def widget_source(*lines)
      "class LedgerWidget\n  extend LedgerAsync\n#{lines.map { |line| "  #{line}\n" }.join}end\n"
    end

    def write_generated_job_fixture
      load app_path(write_file('lib/ledger_async.rb', <<~RUBY))
        module LedgerAsync
          def async_method(name)
            klass = Class.new(ActiveJob::Base) do
              def perform(id, force = false); end
            end
            const_set("\#{name.to_s.split('_').map(&:capitalize).join}Worker", klass)
          end
        end
      RUBY
      load app_path(write_file('app/models/ledger_widget.rb', widget_source))
      write_file('app/services/ledger_sync_caller.rb', <<~RUBY)
        class LedgerSyncCaller
          def call(id) = LedgerWidget::SyncNowWorker.perform_later(id)
        end
      RUBY
    end

    def graph_of(index)
      Woods::DependencyGraph.from_h(read_json(index, 'dependency_graph.json'))
    end

    def generated_unit(index)
      Dir[File.join(payload_dir(index), 'jobs', '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path)) }
        .find { |document| document['identifier'] == 'LedgerWidget::SyncNowWorker' }
    end

    def declare_worker(index)
      path = write_file('app/models/ledger_widget.rb', widget_source('async_method :sync_now'))
      load app_path(path)
      Woods::Extractor.new(output_dir: index).extract_changed([path])
    end

    it 'adds the worker when its declaring line appears, and lands the enqueue edge' do
      write_generated_job_fixture
      index = full_extraction
      expect(graph_of(index).node_types('LedgerWidget::SyncNowWorker')).to be_empty

      touched = declare_worker(index)

      expect(touched).to include('LedgerWidget::SyncNowWorker')
      expect(graph_of(index).node_types('LedgerWidget::SyncNowWorker')).to eq([:job])
      expect(graph_of(index).node_types('LedgerWidget')).to eq([:poro])
      expect(graph_of(index).dependents_of('LedgerWidget::SyncNowWorker')).to include('LedgerSyncCaller')
      unit = generated_unit(index)
      expect(unit).to include('file_path' => 'app/models/ledger_widget.rb')
      expect(unit.fetch('metadata')).to include('generated' => true, 'generated_by' => 'async_method',
                                                'job_type' => 'active_job')
      expect(unit.fetch('source_code')).to end_with("\n  async_method :sync_now\n")
      expect(unit.fetch('source_code')).not_to include('Class.new')
      expect(unit.fetch('dependents')).to include('type' => 'service', 'identifier' => 'LedgerSyncCaller')
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'retains the worker when its owner file changes elsewhere, and follows the line when it moves' do
      write_generated_job_fixture
      index = full_extraction
      declare_worker(index)

      path = write_file('app/models/ledger_widget.rb', widget_source('async_method :sync_now', 'def total = 1'))
      load app_path(path)
      touched = Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(touched).to include('LedgerWidget')
      expect(touched).not_to include('LedgerWidget::SyncNowWorker')
      expect(differences(index, full_extraction)).to be_empty

      write_file('app/models/ledger_widget.rb', widget_source('def total = 1', 'async_method(:sync_now)'))
      touched = Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(touched).to include('LedgerWidget::SyncNowWorker')
      expect(generated_unit(index).fetch('source_code')).to end_with("\n  async_method(:sync_now)\n")
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'removes the worker when its declaring line and constant are gone' do
      write_generated_job_fixture
      index = full_extraction
      declare_worker(index)

      path = write_file('app/models/ledger_widget.rb', widget_source)
      LedgerWidget.send(:remove_const, :SyncNowWorker)
      touched = Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(touched).to include('LedgerWidget::SyncNowWorker')
      expect(graph_of(index).node_types('LedgerWidget::SyncNowWorker')).to be_empty
      expect(generated_unit(index)).to be_nil
      expect(differences(index, full_extraction)).to be_empty
    end

    it 'prunes the worker with its deleted owner file' do
      write_generated_job_fixture
      index = full_extraction
      declare_worker(index)

      path = delete_file('app/models/ledger_widget.rb')
      Object.send(:remove_const, :LedgerWidget)
      Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(graph_of(index).node_types('LedgerWidget::SyncNowWorker')).to be_empty
      expect(differences(index, full_extraction)).to be_empty
    end
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

    # The re-add reads the moved file to learn the constant its loader path
    # names. Under a POSIX locale that read must not fail on a multibyte byte,
    # or the rescue returns no names and the model stays missing.
    it 're-adds a moved multibyte model after ONE run under a US-ASCII default external encoding' do
      write_file('app/models/ledger_tag.rb', <<~RUBY)
        # Ledger tag — labels entries
        class LedgerTag < ApplicationRecord
          self.table_name = "posts"
        end
      RUBY
      load app_path('app/models/ledger_tag.rb')

      index_dir = Dir.mktmpdir('woods_diff_multibyte')
      (@scratch_dirs ||= []) << index_dir
      with_posix_default_external do
        Woods::Extractor.new(output_dir: index_dir).extract_all
        move_file('app/models/ledger_tag.rb', 'app/services/ledger_tag.rb')
        Woods::Extractor.new(output_dir: index_dir).extract_changed(%w[app/models/ledger_tag.rb
                                                                       app/services/ledger_tag.rb])
      end

      # The comparison helpers read artifacts with the suite locale, so they run outside the block.
      expect(differences(index_dir, full_extraction)).to be_empty

      index = index_snapshot(index_dir)
      expect(index['models'].count { |e| e['identifier'] == 'LedgerTag' }).to eq(1)
      expect(index['services'].map { |e| e['identifier'] }).to include('LedgerTag')
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
      %w[app/services/tag.rb app/services/ledger_tag.rb app/models/admin/user.rb app/models/public/user.rb
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

    it 'stays equivalent as inherited actions change through the base controller and routes' do
      base = 'app/controllers/base_gauges_controller.rb'
      base_source = lambda do |body|
        "class BaseGaugesController < ApplicationController\n  def show\n    #{body}\n  end\n\n  " \
          "def export\n    @gauges = Post.all\n  end\nend\n"
      end
      routes = lambda do |*lines|
        write_file('config/routes.rb', <<~RUBY)
          Rails.application.routes.draw do
            resources :posts
            #{lines.join("\n  ")}
          end
        RUBY
        Rails.application.reload_routes!
        'config/routes.rb'
      end
      write_file(base, base_source.call('@gauge = Post.recent'))
      load app_path(base)
      write_file('app/controllers/gauges_controller.rb', "class GaugesController < BaseGaugesController\nend\n")
      load app_path('app/controllers/gauges_controller.rb')
      routes.call('resources :gauges, only: %i[show]')

      run_sequence([
                     lambda {
                       write_file(base, base_source.call('@gauge = Post.archived'))
                       load app_path(base)
                       base
                     },
                     -> { routes.call('resources :gauges, only: %i[show]', "get 'gauges/export', to: 'gauges#export'") }
                   ])
    end

    # W-14: best-effort mode keeps the same contract, failures included:
    # skipped_files.json's flow_failures must match a full run's.
    it 'stays equivalent in best-effort mode while one action fails to assemble' do
      Woods.configuration.precompute_flows = :best_effort
      allow_any_instance_of(Woods::FlowAssembler).to receive(:assemble).and_wrap_original do |original, entry, **opts|
        raise StandardError, "cannot trace #{entry}" if entry == 'SievesController#show'

        original.call(entry, **opts)
      end
      sieves = lambda do |scope, show|
        actions = ["  def index\n    @sieves = Post.#{scope}\n  end\n"]
        actions << "  def show\n    @sieve = Post.find(params[:id])\n  end\n" if show
        write_file('app/controllers/sieves_controller.rb',
                   "class SievesController < ApplicationController\n#{actions.join("\n")}end\n")
        load app_path('app/controllers/sieves_controller.rb')
        'app/controllers/sieves_controller.rb'
      end
      run_sequence([-> { sieves.call('recent', false) }, -> { sieves.call('recent', true) },
                    -> { sieves.call('all', true) }])
    end

    # ThingsController stays in the controller descendants for the rest of
    # the process and resolves to this file. Fold it into the pristine tree
    # so the runtime and the filesystem keep agreeing in every later
    # example. The gauges controllers leak the same way.
    after do
      %w[things_controller base_gauges_controller gauges_controller sieves_controller].each do |name|
        created = app_path("app/controllers/#{name}.rb")
        FileUtils.cp(created, File.join(@pristine_root, "app/controllers/#{name}.rb")) if File.exist?(created)
      end
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

  # Table units come from the live schema and from which models claim each
  # table; migrations, views and declared consumers resolve table names through
  # the same catalog. Every scenario changes the database or a file and holds
  # the incremental index to a full extraction of the same state.
  describe 'database tables and external consumers (#669, #681)' do
    def connection
      ActiveRecord::Base.connection
    end

    def unit_json(index_dir, type_dir, identifier)
      unit_snapshot(index_dir).find do |key, data|
        key.start_with?("#{type_dir}/") && data['identifier'] == identifier
      end&.last
    end

    def edges(unit, via)
      unit.fetch('dependencies').select { |dep| dep['via'] == via }.map { |dep| dep['target'] }
    end

    # Earlier examples leave extra models on `posts` for the rest of the
    # process, so the owner is whichever claimant the table unit names.
    def posts_owner(index_dir)
      metadata = unit_json(index_dir, 'database_tables', 'table:posts')['metadata']
      expect(metadata['models']).to include('Post')
      expect(metadata['model']).to eq(metadata['models'].first)
      metadata['model']
    end

    def migration(name, body)
      "class #{name} < ActiveRecord::Migration[7.0]\n  def change\n    #{body}\n  end\nend\n"
    end

    after do
      %i[audit_rows parcel_events].each { |table| connection.drop_table(table, if_exists: true) }
    end

    it 'publishes one unit per live table, with model ownership and the model edge, in a full extraction' do
      connection.create_table(:audit_rows) { |t| t.string :note }
      index = full_extraction

      posts = unit_json(index, 'database_tables', 'table:posts')
      audit = unit_json(index, 'database_tables', 'table:audit_rows')

      expect(posts['metadata']).to include('model' => posts_owner(index), 'model_less' => false, 'primary_key' => 'id')
      expect(posts['metadata']['columns'].map { |column| column['name'] }).to include('id', 'title', 'status')
      expect(posts['dependents']).to include({ 'type' => 'model', 'identifier' => 'Post' })
      expect(audit['metadata']).to include('model' => nil, 'model_less' => true)
      expect(edges(unit_json(index, 'models', 'Post'), 'table')).to eq(['table:posts'])
      expect(unit_snapshot(index).keys.grep(%r{\Adatabase_tables/})).not_to include(a_string_matching(/schema_migr/))
      expect(read_json(index, 'graph_analysis.json')['unmodelled_tables']).to include('table:audit_rows')
    end

    it 'publishes byte-identical table units on a repeat full extraction' do
      connection.create_table(:audit_rows) { |t| t.string :note }

      expect(differences(full_extraction, full_extraction)).to be_empty
    end

    it 'follows a table and its migration as they are created, changed and removed' do
      path = 'db/migrate/20240301000000_create_audit_rows.rb'
      index = run_sequence(
        [
          lambda {
            connection.create_table(:audit_rows) { |t| t.string :note }
            write_file(path, migration('CreateAuditRows', 'create_table(:audit_rows) { |t| t.string :note }'))
          },
          lambda {
            connection.add_column(:audit_rows, :post_id, :integer)
            write_file(path, migration('CreateAuditRows', "create_table(:audit_rows) { |t| t.string :note }\n    " \
                                                          'add_reference :audit_rows, :post'))
          }
        ]
      )

      unit = unit_json(index, 'migrations', 'CreateAuditRows')
      expect(edges(unit, 'migrates')).to eq(%w[table:audit_rows table:posts])
      expect(edges(unit, 'table_name')).to eq([])
      expect(edges(unit, 'reference')).to eq([posts_owner(index)])
      expect(unit_json(index, 'database_tables', 'table:audit_rows')['metadata']['column_count']).to eq(3)

      connection.drop_table(:audit_rows)
      write_file(path, migration('CreateAuditRows', 'create_table(:audit_rows) { |t| t.text :note }'))
      Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(differences(index, full_extraction)).to be_empty
      expect(unit_json(index, 'database_tables', 'table:audit_rows')).to be_nil
      unit = unit_json(index, 'migrations', 'CreateAuditRows')
      expect(edges(unit, 'migrates')).to eq([])
      expect(unit['metadata']['tables_unresolved']).to eq(['audit_rows'])

      delete_file(path)
      Woods::Extractor.new(output_dir: index).extract_changed([path])
      expect(differences(index, full_extraction)).to be_empty
    end

    describe 'a model claiming a table that had none' do
      # `ParcelEvent` stays in ActiveRecord::Base.descendants for the rest of
      # the process, so its file and its table join the pristine state.
      after do
        FileUtils.cp(app_path('app/models/parcel_event.rb'), File.join(@pristine_root, 'app/models/parcel_event.rb'))
        connection.create_table(:parcel_events, if_not_exists: true) { |t| t.string :kind }
      end

      it 'flips the table to modelled and gives its unchanged migration a model edge' do
        connection.create_table(:parcel_events, if_not_exists: true) { |t| t.string :kind }
        path = 'db/migrate/20240302000000_create_parcel_events.rb'
        index = run_sequence(
          [
            lambda {
              write_file(path, migration('CreateParcelEvents', 'create_table(:parcel_events) { |t| t.string :kind }'))
            },
            lambda {
              write_file('app/models/parcel_event.rb', "class ParcelEvent < ApplicationRecord\nend\n")
              load app_path('app/models/parcel_event.rb')
              'app/models/parcel_event.rb'
            }
          ]
        )

        expect(unit_json(index, 'database_tables', 'table:parcel_events')['metadata'])
          .to include('model' => 'ParcelEvent', 'model_less' => false)
        expect(edges(unit_json(index, 'migrations', 'CreateParcelEvents'), 'table_name')).to eq(['ParcelEvent'])
        expect(edges(unit_json(index, 'models', 'ParcelEvent'), 'table')).to eq(['table:parcel_events'])
      end
    end

    describe 'a loaded model whose table appears and vanishes' do
      # `ParcelNote` stays in ActiveRecord::Base.descendants for the rest of
      # the process, so its file and its table join the pristine state.
      after do
        FileUtils.cp(app_path('app/models/parcel_note.rb'), File.join(@pristine_root, 'app/models/parcel_note.rb'))
        connection.create_table(:parcel_notes, if_not_exists: true) { |t| t.string :body }
      end

      it 'refreshes the unchanged model table edge when only the migration and the database change' do
        write_file('app/models/parcel_note.rb', "class ParcelNote < ApplicationRecord\nend\n")
        load app_path('app/models/parcel_note.rb')
        path = 'db/migrate/20240306000000_create_parcel_notes.rb'
        index = run_sequence(
          [
            lambda {
              connection.create_table(:parcel_notes) { |t| t.string :body }
              write_file(path, migration('CreateParcelNotes', 'create_table(:parcel_notes) { |t| t.string :body }'))
            },
            lambda {
              connection.drop_table(:parcel_notes)
              write_file(path, migration('CreateParcelNotes', 'drop_table :parcel_notes'))
            }
          ]
        )

        expect(edges(unit_json(index, 'models', 'ParcelNote'), 'table')).to eq([])
      end
    end

    it 'gives an unchanged view an edge when its source table appears' do
      index = run_sequence(
        [
          -> { write_file('db/views/audit_summary_v01.sql', 'SELECT p.id FROM posts p JOIN audit_rows a ON true') },
          lambda {
            connection.create_table(:audit_rows) { |t| t.string :note }
            write_file('db/migrate/20240303000000_create_audit_rows.rb',
                       migration('CreateAuditRows', 'create_table(:audit_rows) { |t| t.string :note }'))
          }
        ]
      )

      view = unit_json(index, 'database_views', 'audit_summary')
      expect(edges(view, 'view_source')).to eq(%w[table:audit_rows table:posts])
      expect(edges(view, 'table_name')).to eq([posts_owner(index)])
    end

    it 'brings tables and everything that resolves them back into agreement through refresh' do
      index = Dir.mktmpdir('woods_refresh_tables')
      (@scratch_dirs ||= []) << index
      write_file('db/migrate/20240304000000_create_audit_rows.rb',
                 migration('CreateAuditRows', 'create_table(:audit_rows) { |t| t.string :note }'))
      Woods::Extractor.new(output_dir: index).extract_all

      connection.create_table(:audit_rows) { |t| t.string :note }
      result = Woods::Extractor.new(output_dir: index).refresh(:database_tables)

      expect(result[:types]).to include(:database_tables, :migrations, :database_views, :external_consumers)
      expect(differences(index, full_extraction)).to be_empty
      expect(edges(unit_json(index, 'migrations', 'CreateAuditRows'), 'migrates')).to eq(['table:audit_rows'])
    end

    describe 'declared external consumers' do
      let(:declared) { 'config/woods/external_consumers.yml' }

      around do |example|
        Woods.configuration.external_table_consumers_path = declared
        Woods.configuration.external_table_consumers = { 'reporting' => %w[comments] }
        example.run
      ensure
        Woods.configuration.external_table_consumers_path = nil
        Woods.configuration.external_table_consumers = {}
      end

      it 'follows the declared file as it is created, edited and deleted' do
        index = run_sequence(
          [
            -> { write_file(declared, "storefront:\n  - posts\n  - audit_rows\n") },
            lambda {
              write_file(declared, "storefront:\n  reads:\n    - posts\n    - comments\n  writes:\n    - comments\n" \
                                   "reporting:\n  - posts\n")
            }
          ]
        )

        storefront = unit_json(index, 'external_consumers', 'external:storefront')
        expect(edges(storefront, 'reads_table')).to eq(%w[table:comments table:posts])
        expect(edges(storefront, 'writes_table')).to eq(%w[table:comments])
        expect(storefront['metadata']).to include('declared' => true, 'tables_missing' => [],
                                                  'tables_written' => ['comments'])
        expect(edges(unit_json(index, 'external_consumers', 'external:reporting'), 'reads_table'))
          .to eq(%w[table:comments table:posts])
        expect(unit_json(index, 'database_tables', 'table:posts')['dependents'])
          .to include({ 'type' => 'external_consumer', 'identifier' => 'external:storefront' })

        delete_file(declared)
        Woods::Extractor.new(output_dir: index).extract_changed([declared])

        expect(differences(index, full_extraction)).to be_empty
        expect(unit_json(index, 'external_consumers', 'external:storefront')).to be_nil
        expect(edges(unit_json(index, 'external_consumers', 'external:reporting'), 'reads_table'))
          .to eq(['table:comments'])
      end

      it 'links a declared table once it exists, without the declaration changing' do
        write_file(declared, "storefront:\n  - audit_rows\n")
        index = run_sequence(
          [
            lambda {
              connection.create_table(:audit_rows) { |t| t.string :note }
              write_file('db/migrate/20240305000000_create_audit_rows.rb',
                         migration('CreateAuditRows', 'create_table(:audit_rows) { |t| t.string :note }'))
            }
          ]
        )

        expect(edges(unit_json(index, 'external_consumers', 'external:storefront'), 'reads_table'))
          .to eq(['table:audit_rows'])
      end

      it 'keeps the published generation when the declared file is malformed' do
        write_file(declared, "storefront:\n  - posts\n")
        index = Dir.mktmpdir('woods_consumers_malformed')
        (@scratch_dirs ||= []) << index
        Woods::Extractor.new(output_dir: index).extract_all

        write_file(declared, "storefront: posts\n")
        begin
          Woods::Extractor.new(output_dir: index).extract_changed([declared])
        rescue Woods::ExtractionError
          nil
        end

        expect(edges(unit_json(index, 'external_consumers', 'external:storefront'), 'reads_table'))
          .to eq(['table:posts'])
      end
    end
  end

  # ── Test support, route coverage, factory classes ────────────────────────
  #
  # Test mappings resolve names (shared examples, contexts, matchers, helper
  # modules, rake tasks) and routes that live in OTHER files. None of those
  # inputs is in a spec's own bytes, so each example below changes only the
  # input and checks that the untouched spec's unit follows.
  describe 'test support, route coverage and factory classes' do
    def published_unit(dir, type_dir, identifier)
      Dir[File.join(payload_dir(dir), type_dir, '*.json')]
        .reject { |path| File.basename(path) == '_index.json' }
        .map { |path| JSON.parse(File.read(path)) }
        .find { |document| document['identifier'] == identifier }
    end

    def edges(dir, type_dir, identifier, via)
      published_unit(dir, type_dir, identifier)['dependencies']
        .select { |dep| dep['via'] == via }.map { |dep| dep['target'] }
    end

    it 'follows a shared example through creation, rename and deletion of its support file' do
      spec = 'spec/models/widget_behavior_spec.rb'
      write_file(spec, "RSpec.describe Post do\n  it_behaves_like 'an accessible page'\nend\n")

      index = run_sequence([
                             lambda {
                               write_file('spec/support/shared/pages.rb',
                                          "RSpec.shared_examples 'an accessible page' do\nend\n")
                             }
                           ])
      expect(edges(index, 'test_mappings', spec, 'behaves_like')).to eq(['spec/support/shared/pages.rb'])
      expect(published_unit(index, 'test_support', 'spec/support/shared/pages.rb')['metadata'])
        .to include('kind' => 'shared_examples', 'shared_examples' => ['an accessible page'])

      index = run_sequence([
                             lambda {
                               write_file('spec/support/shared/pages.rb',
                                          "RSpec.shared_examples 'a readable page' do\nend\n")
                             }
                           ])
      expect(edges(index, 'test_mappings', spec, 'behaves_like')).to eq([])

      index = run_sequence([-> { delete_file('spec/support/shared/pages.rb') }])
      expect(published_unit(index, 'test_support', 'spec/support/shared/pages.rb')).to be_nil
    end

    it 'follows contexts, matchers and helper modules defined after the spec that uses them' do
      spec = 'spec/features/plans_spec.rb'
      write_file(spec, <<~RUBY)
        RSpec.feature 'Plans' do
          include AnalyticsHelpers
          include_context 'with billing stubs'
          scenario('choosing') { expect(page).to have_combobox('Plan') }
        end
      RUBY

      index = run_sequence([
                             lambda {
                               write_file('spec/support/billing_stubs.rb',
                                          "RSpec.shared_context 'with billing stubs' do\nend\n")
                             },
                             lambda {
                               write_file('spec/support/matchers/combobox.rb',
                                          "RSpec::Matchers.define :have_combobox do |label|\nend\n")
                             },
                             lambda {
                               write_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")
                             }
                           ])

      expect(published_unit(index, 'test_mappings', spec)['dependencies']).to include(
        { 'type' => 'test_support', 'target' => 'spec/support/billing_stubs.rb', 'via' => 'includes_context' },
        { 'type' => 'test_support', 'target' => 'spec/support/matchers/combobox.rb', 'via' => 'uses_matcher' },
        { 'type' => 'test_support', 'target' => 'spec/support/analytics_helpers.rb', 'via' => 'includes_helper' }
      )
    end

    it 'recomputes included_for on a helper module when another file changes its includes' do
      write_file('spec/support/analytics_helpers.rb', "module AnalyticsHelpers\nend\n")
      helper = 'spec/support/analytics_helpers.rb'

      index = run_sequence([
                             lambda {
                               write_file('spec/rails_helper.rb',
                                          "RSpec.configure { |c| c.include AnalyticsHelpers, type: :feature }\n")
                             }
                           ])
      expect(published_unit(index, 'test_support', helper)['metadata']['included_for']).to eq(['feature'])

      index = run_sequence([
                             lambda {
                               write_file('spec/rails_helper.rb', <<~RUBY)
                                 RSpec.configure { |c| c.include AnalyticsHelpers, type: %i[system request] }
                               RUBY
                             }
                           ])
      expect(published_unit(index, 'test_support', helper)['metadata']['included_for']).to eq(%w[request system])
    end

    # The route table is not in any spec file. Test mappings are route
    # consumers, so a routes change re-extracts them.
    it 're-extracts test mappings when the routes change' do
      spec = 'spec/features/comments_spec.rb'
      write_file(spec, <<~RUBY)
        RSpec.feature 'Comments' do
          scenario 'browsing' do
            visit posts_path
            visit comments_path
            visit "/comments"
          end
        end
      RUBY
      write_file('spec/requests/posts_spec.rb', <<~RUBY)
        RSpec.describe 'Posts' do
          it('creates') { post posts_path }
          it('destroys') { delete "/posts/1" }
        end
      RUBY

      baseline = full_extraction
      expect(edges(baseline, 'test_mappings', spec, 'exercises_route')).to eq(['GET /posts'])
      expect(edges(baseline, 'test_mappings', 'spec/requests/posts_spec.rb', 'exercises_route')).to eq(['POST /posts'])

      index = run_sequence([
                             lambda {
                               write_file('config/routes.rb', <<~RUBY)
                                 Rails.application.routes.draw do
                                   resources :posts, only: %i[index show create destroy]
                                   resources :comments, only: [:index]
                                 end
                               RUBY
                               Rails.application.reload_routes!
                               'config/routes.rb'
                             }
                           ])

      expect(edges(index, 'test_mappings', spec, 'exercises_route')).to eq(['GET /comments', 'GET /posts'])
      expect(edges(index, 'test_mappings', 'spec/requests/posts_spec.rb', 'exercises_route'))
        .to eq(['DELETE /posts/:id', 'POST /posts'])
      expect(published_unit(index, 'routes', 'GET /comments')['dependents'])
        .to include(hash_including('identifier' => spec))
    end

    it 'follows a rake namespace describe as tasks are added and removed' do
      spec = 'spec/lib/tasks/reports_spec.rb'
      write_file(spec, "RSpec.describe 'reports' do\n  it('runs') {}\nend\n")

      index = run_sequence([-> { write_file('lib/tasks/reports.rake', rake_source('reports', %w[daily weekly])) }])
      expect(edges(index, 'test_mappings', spec, 'test_coverage')).to eq(%w[reports:daily reports:weekly])

      index = run_sequence([-> { write_file('lib/tasks/reports.rake', rake_source('reports', %w[daily])) }])
      expect(edges(index, 'test_mappings', spec, 'test_coverage')).to eq(%w[reports:daily])

      index = run_sequence([-> { delete_file('lib/tasks/reports.rake') }])
      expect(published_unit(index, 'test_mappings', spec)['dependencies']).to eq([])
    end

    it 'resolves a factory class through a parent defined in another file' do
      write_file('spec/factories/a_children.rb', "FactoryBot.define do\n  factory :featured_post, parent: :post\nend\n")

      index = run_sequence([
                             lambda {
                               write_file('spec/factories/posts.rb',
                                          "FactoryBot.define do\n  factory :post, class: '::Post' do\n  end\nend\n")
                             }
                           ])

      expect(published_unit(index, 'factories', 'featured_post')['metadata']['model_class']).to eq('Post')
      expect(edges(index, 'factories', 'featured_post', 'factory_for')).to eq(['Post'])
    end

    it 'moves a factory-directory file between test_support and factories as it gains a factory' do
      callbacks = 'spec/factories/callbacks.rb'
      index = run_sequence([
                             lambda {
                               write_file(callbacks, "FactoryBot.define do\n  after(:build) { |record| record }\nend\n")
                             }
                           ])
      expect(published_unit(index, 'test_support', callbacks)['metadata']['kind']).to eq('configuration')

      index = run_sequence([
                             lambda {
                               write_file(callbacks, <<~RUBY)
                                 FactoryBot.define do
                                   factory :callback_post, class: 'Post' do
                                   end
                                 end
                               RUBY
                             }
                           ])
      expect(published_unit(index, 'test_support', callbacks)).to be_nil
      expect(published_unit(index, 'factories', 'callback_post')).not_to be_nil
    end

    it 'publishes byte-identical test units on repeat full extractions' do
      write_file('spec/support/shared/pages.rb', "RSpec.shared_examples 'an accessible page' do\nend\n")
      write_file('spec/features/pages_spec.rb', <<~RUBY)
        RSpec.feature 'Pages' do
          it_behaves_like 'an accessible page'
          scenario('x') { visit posts_path }
        end
      RUBY

      expect(differences(full_extraction, full_extraction)).to be_empty
    end
  end

  # ── Randomized differential run ──────────────────────────────────────────

  # The gap-specific examples above pin known failures; this is the part that
  # finds the unknown ones. Seeds are fixed so a failure is reproducible.
  describe 'constant paths in dependency edges' do
    def edges_of(index, type, identifier)
      unit = unit_snapshot(index).values.find { |data| data['type'] == type && data['identifier'] == identifier }
      unit.fetch('dependencies').map { |dep| dep.values_at('type', 'target', 'via') }
    end

    def remove_model(name)
      return unless Object.const_defined?(name, false)

      Object.const_get(name).abstract_class = true
      Object.send(:remove_const, name)
    end

    it 'keeps whole GraphQL constant paths as the referencing file changes' do
      source = <<~RUBY
        module Mutations
          class PathShip < Mutations::BaseMutation
            argument :input, Types::Inputs::PathDraft, required: true
            field :stamped_at, GraphQL::Types::ISO8601DateTime, null: true

            def resolve(input:)
              Resolvers::PathLedger::Create.new(context).call(input)
              ::Post.find(input[:id])
            end
          end
        end
      RUBY
      path = write_file('app/graphql/mutations/path_ship.rb', source)
      index = full_extraction

      expect(edges_of(index, 'graphql_mutation', 'Mutations::PathShip')).to eq(
        [%w[graphql_type Types::Inputs::PathDraft type_reference],
         %w[graphql_resolver Resolvers::PathLedger::Create code_reference],
         %w[model Post code_reference]]
      )

      write_file(path, source.sub('Create.new', 'Update.new').sub('::Post.find', 'Comment.where'))
      Woods::Extractor.new(output_dir: index).extract_changed([path])

      expect(differences(index, full_extraction)).to be_empty
      expect(edges_of(index, 'graphql_mutation', 'Mutations::PathShip')).to include(
        %w[graphql_resolver Resolvers::PathLedger::Update code_reference], %w[model Comment code_reference]
      )
    end

    it 'resolves a relative GraphQL path against loaded constants in both modes' do
      base = write_file('app/graphql/types/path_base_type.rb', <<~RUBY)
        module Types
          class PathBaseType
            def self.field(*, **); end
          end
        end
      RUBY
      crate = write_file('app/graphql/types/path_crate_type.rb', <<~RUBY)
        module Types
          class PathCrateType < PathBaseType
            field :label, String, null: false
          end
        end
      RUBY
      [base, crate].each { |relative| load app_path(relative) }
      source = <<~RUBY
        module Types
          class PathPalletType < PathBaseType
            field :crate, PathCrateType, null: true
          end
        end
      RUBY
      # The referencing file stays unloaded (this process has no graphql-ruby):
      # resolution needs only the scopes and targets that are loaded.
      pallet = write_file('app/graphql/types/path_pallet_type.rb', source)
      index = full_extraction

      expect(edges_of(index, 'graphql_type', 'Types::PathPalletType')).to eq(
        [%w[graphql_type Types::PathBaseType type_reference], %w[graphql_type Types::PathCrateType type_reference]]
      )

      write_file(pallet, source.sub('null: true', 'null: false'))
      Woods::Extractor.new(output_dir: index).extract_changed([pallet])
      expect(differences(index, full_extraction)).to be_empty

      # Deleting the target re-extracts its dependents, in both modes.
      delete_file(crate)
      Types.send(:remove_const, :PathCrateType)
      Woods::Extractor.new(output_dir: index).extract_changed([crate])
      expect(differences(index, full_extraction)).to be_empty
    ensure
      Object.send(:remove_const, :Types) if Object.const_defined?(:Types, false)
    end

    it 'publishes a mixin declared in an initializer and lands the extend edge on it' do
      initializer = write_file('config/initializers/path_persistence.rb', <<~RUBY)
        module PathPersistence
          module ClassMethods
            def persisted_scope
              'original'
            end
          end
        end

        # No model mixes this one in; a service extends it.
        module PathCountable
          def count_all
            0
          end
        end
      RUBY
      load app_path(initializer)
      service = write_file('app/services/path_tally_service.rb', <<~RUBY)
        class PathTallyService
          extend PathCountable
        end
      RUBY
      load app_path(service)
      model_source = <<~RUBY
        class PathLedger < ApplicationRecord
          self.table_name = 'posts'
          extend PathPersistence::ClassMethods
          belongs_to :path_trackable, polymorphic: true
          has_many :path_comments, class_name: '::Comment', foreign_key: :post_id
        end
      RUBY
      model = write_file('app/models/path_ledger.rb', model_source)
      load app_path(model)
      index = full_extraction

      units = unit_snapshot(index).values
      mixin = units.find { |data| data['type'] == 'concern' && data['identifier'] == 'PathPersistence' }
      expect(mixin.fetch('file_path')).to eq(initializer)
      countable = units.find { |data| data['type'] == 'concern' && data['identifier'] == 'PathCountable' }
      expect(countable.fetch('file_path')).to eq(initializer)
      ledger = units.find { |data| data['type'] == 'model' && data['identifier'] == 'PathLedger' }
      expect(ledger.dig('metadata', 'polymorphic_interfaces')).to eq(['path_trackable'])
      edges = edges_of(index, 'model', 'PathLedger')
      expect(edges).to include(%w[concern PathPersistence extend], %w[model Comment has_many])
      expect(edges.map { |edge| edge[1] }).not_to include('PathTrackable', 'PathPersistence::ClassMethods', '::Comment')

      write_file(model, model_source.sub("'posts'", "'posts' # edited"))
      Woods::Extractor.new(output_dir: index).extract_changed([model])
      expect(differences(index, full_extraction)).to be_empty

      write_file(service, "class PathTallyService\n  extend PathCountable\n  LIMIT = 2\nend\n")
      Woods::Extractor.new(output_dir: index).extract_changed([service])
      expect(differences(index, full_extraction)).to be_empty
    ensure
      remove_model(:PathLedger)
      %i[PathPersistence PathCountable PathTallyService].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name, false)
      end
    end
  end

  describe 'nested classes in GraphQL type files' do
    # A loaded type counts as GraphQL only through graphql-ruby's ancestry, so
    # this process stands in for the gem: a schema with no descendants and an
    # Object base the fixture types inherit from.
    before do
      stub_const('GraphQL::Schema', Class.new { def self.descendants = [] })
      stub_const('GraphQL::Schema::Object', Class.new { def self.field(*, **); end })
    end

    after { Object.send(:remove_const, :Types) if Object.const_defined?(:Types, false) }

    def nested_units(index)
      unit_snapshot(index).values.select do |data|
        data['type'] == 'poro' && data['identifier'].start_with?('Types::NestCartType::')
      end
    end

    def cart_source(method: 'amount', coupon: false, error: true)
      <<~RUBY
        module Types
          class NestCartType < Types::NestBaseType
            field :id, String, null: false

            class Discount
              def #{method}; end
            end
            Line = Struct.new(:sku, :qty)
            #{'class Error < StandardError; end' if error}
            #{"class Coupon\n      def code; end\n    end" if coupon}
            class Bare
            end
          end
        end
      RUBY
    end

    it 'adds, changes, removes and references nested classes equivalently to a full extraction' do
      base = write_file('app/graphql/types/nest_base_type.rb', <<~RUBY)
        module Types
          class NestBaseType < GraphQL::Schema::Object
          end
        end
      RUBY
      load app_path(base)
      cart = write_file('app/graphql/types/nest_cart_type.rb', cart_source)
      load app_path(cart)
      # Unloaded in this process: its references resolve against the loaded nested classes.
      mutation = write_file('app/graphql/mutations/nest_apply_discount.rb', <<~RUBY)
        module Mutations
          class NestApplyDiscount < Mutations::BaseMutation
            field :ok, Boolean, null: false

            def resolve
              Types::NestCartType::Discount.new
            end
          end
        end
      RUBY
      index = full_extraction

      units = nested_units(index)
      expect(units.map { |data| data['identifier'] }).to contain_exactly(
        'Types::NestCartType::Discount', 'Types::NestCartType::Line', 'Types::NestCartType::Error'
      )
      expect(units.map { |data| data['file_path'] }.uniq).to eq([cart])
      expect(units.map { |data| data.dig('metadata', 'discovered_via') }.uniq).to eq(['owner_fallback'])
      expect(unit_snapshot(index).values.count { |data| data['identifier'] == 'Types::NestCartType' }).to eq(1)
      graph = read_json(index, 'dependency_graph.json')
      expect(graph.fetch('edges').fetch('Mutations::NestApplyDiscount'))
        .to include('target' => 'Types::NestCartType::Discount', 'via' => 'code_reference')
      mutation_unit = unit_snapshot(index).values.find { |data| data['identifier'] == 'Mutations::NestApplyDiscount' }
      expect(mutation_unit.fetch('dependencies'))
        .to include('type' => 'poro', 'target' => 'Types::NestCartType::Discount', 'via' => 'code_reference')
      expect(graph.fetch('reverse').fetch('Types::NestCartType::Discount')).to include('Mutations::NestApplyDiscount')

      # Change: the nested unit's own source moves with the type file.
      write_file(cart, cart_source(method: 'total'))
      load app_path(cart)
      Woods::Extractor.new(output_dir: index).extract_changed([cart])
      expect(differences(index, full_extraction)).to be_empty
      discount = nested_units(index).find { |data| data['identifier'] == 'Types::NestCartType::Discount' }
      expect(discount.fetch('source_code')).to include('def total')

      # Add: a new nested class joins without a full run.
      write_file(cart, cart_source(method: 'total', coupon: true))
      load app_path(cart)
      Woods::Extractor.new(output_dir: index).extract_changed([cart])
      expect(differences(index, full_extraction)).to be_empty
      expect(nested_units(index).map { |data| data['identifier'] }).to include('Types::NestCartType::Coupon')

      # Remove: the constant outlives its declaration, the unit does not.
      write_file(cart, cart_source(method: 'total', coupon: true, error: false))
      Woods::Extractor.new(output_dir: index).extract_changed([cart])
      expect(differences(index, full_extraction)).to be_empty
      expect(nested_units(index).map { |data| data['identifier'] }).not_to include('Types::NestCartType::Error')

      # An unrelated edit does not redo the file's nested units.
      write_file(mutation, File.read(app_path(mutation)).sub('null: false', 'null: true'))
      Woods::Extractor.new(output_dir: index).extract_changed([mutation])
      expect(differences(index, full_extraction)).to be_empty

      # Delete the type file: every unit at that path goes.
      delete_file(cart)
      Woods::Extractor.new(output_dir: index).extract_changed([cart])
      expect(differences(index, full_extraction)).to be_empty
      expect(nested_units(index)).to be_empty
    end
  end

  describe 'helper call edges' do
    let(:helper) { 'app/helpers/hlp_date_helper.rb' }
    let(:rival) { 'app/helpers/hlp_ledger_helper.rb' }
    let(:template) { 'app/views/gen/hc_show.html.erb' }

    def helper_source(method_name, module_name: 'HlpDateHelper')
      "module #{module_name}\n  def #{method_name}(value) = value\nend\n"
    end

    def rival_source
      helper_source('fancy_date', module_name: 'HlpLedgerHelper')
    end

    def helper_edges(index_dir, identifier)
      unit = unit_snapshot(index_dir).values.find { |data| data['identifier'] == identifier }
      unit.fetch('dependencies').select { |edge| %w[helper_call helper_method].include?(edge['via']) }
    end

    it 'follows a helper module through creation, a renamed method, a rival definition and deletion' do
      index_dir = run_sequence([
                                 -> { write_file(helper, helper_source('pretty_date')) },
                                 -> { write_file(template, "<p><%= pretty_date(@post.created_at) %></p>\n") },
                                 # The template did not change, but what its call means did.
                                 -> { write_file(helper, helper_source('fancy_date')) },
                                 -> { write_file(template, "<p><%= fancy_date(@post.created_at) %></p>\n") },
                                 -> { write_file(rival, rival_source) },
                                 -> { delete_file(helper) },
                                 -> { delete_file(rival) }
                               ])

      expect(helper_edges(index_dir, 'gen/hc_show.html.erb')).to eq([])
    end

    it 'records the edge, the rename and the ambiguity at each step' do
      index_dir = run_sequence([-> { write_file(helper, helper_source('pretty_date')) },
                                -> { write_file(template, "<p><%= pretty_date(@post.created_at) %></p>\n") }])
      expect(helper_edges(index_dir, 'gen/hc_show.html.erb'))
        .to eq([{ 'type' => 'poro', 'target' => 'HlpDateHelper', 'via' => 'helper_call' }])

      Woods::Extractor.new(output_dir: index_dir).extract_changed([write_file(helper, helper_source('fancy_date'))])
      expect(helper_edges(index_dir, 'gen/hc_show.html.erb')).to eq([])

      changed = [write_file(template, "<p><%= fancy_date(1) %></p>\n"), write_file(rival, rival_source)]
      Woods::Extractor.new(output_dir: index_dir).extract_changed(changed)
      unit = unit_snapshot(index_dir).values.find { |data| data['identifier'] == 'gen/hc_show.html.erb' }
      expect(helper_edges(index_dir, 'gen/hc_show.html.erb').map { |edge| edge['target'] })
        .to eq(%w[HlpDateHelper HlpLedgerHelper])
      expect(unit.dig('metadata', 'ambiguous_helper_calls')).to eq('fancy_date' => %w[HlpDateHelper HlpLedgerHelper])
      expect(differences(index_dir, full_extraction)).to be_empty
    end

    it 'links a view to the controller that declares the helper_method it calls' do
      controller = 'app/controllers/hc_widgets_controller.rb'
      index_dir = run_sequence([
                                 lambda do
                                   write_file(controller, <<~RUBY)
                                     class HcWidgetsController < ApplicationController
                                       helper_method :current_hc_widget

                                       def show; end

                                       private

                                       def current_hc_widget = nil
                                     end
                                   RUBY
                                   load app_path(controller)
                                   controller
                                 end,
                                 -> { write_file('app/views/hc_widgets/show.html.erb', "<%= current_hc_widget %>\n") },
                                 # A layout has no owning controller and cannot reach the declaration.
                                 -> { write_file('app/views/layouts/hc.html.erb', "<%= current_hc_widget %>\n") },
                                 # The default context's own file re-runs the ownerless consumers.
                                 lambda do
                                   write_file('app/controllers/application_controller.rb', <<~RUBY)
                                     # frozen_string_literal: true

                                     # edited
                                     class ApplicationController < ActionController::Base
                                     end
                                   RUBY
                                 end
                               ])

      expect(helper_edges(index_dir, 'hc_widgets/show.html.erb'))
        .to eq([{ 'type' => 'controller', 'target' => 'HcWidgetsController', 'via' => 'helper_method' }])
      expect(helper_edges(index_dir, 'layouts/hc.html.erb')).to eq([])
      controller_unit = unit_snapshot(index_dir).values.find { |data| data['identifier'] == 'HcWidgetsController' }
      expect(controller_unit.dig('metadata', 'helper_methods')).to eq(%w[current_hc_widget])
    end

    # `HcWidgetsController` stays in ActionController::Base.descendants for the
    # rest of the process. Fold its file into the pristine tree so the runtime
    # and the filesystem keep agreeing in every later example.
    after do
      source = app_path('app/controllers/hc_widgets_controller.rb')
      FileUtils.cp(source, File.join(@pristine_root, 'app/controllers/hc_widgets_controller.rb')) if File.exist?(source)
    end
  end

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

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength -- a lookup table
  # of file shape to sample content; one branch per extractor under test.
  def artifact_source(relative, nonce, random)
    base = File.basename(relative).sub(/\.\w+(\.\w+)?\z/, '')

    case relative
    when /\.md\z/ then doc_source(base, nonce)
    when /\.rake\z/ then rake_source(base, Array.new(1 + random.rand(3)) { |n| "task#{n}" })
    when /\.yml\z/ then "en:\n  #{base}: value_#{nonce}\n"
    when /\.sql\z/ then "SELECT #{nonce} AS answer;\n"
    when /\.erb\z/
      "<div><%= Rails.cache.fetch('#{base}_#{nonce}') { 1 } %> <%= hlp_#{random.rand(6)}_label(1) %></div>\n"
    when /\.haml\z/ then "%div= Rails.cache.fetch('#{base}_#{nonce}') { 1 }\n%p= hlp_#{random.rand(6)}_label(1)\n"
    when /\.jbuilder\z/ then "json.answer #{nonce}\njson.label hlp_#{random.rand(6)}_label(1)\n"
    when %r{\Aapp/helpers/} then helper_module_source(base)
    when %r{\Adb/migrate/} then migration_source(base, nonce)
    when %r{\Aspec/factories/} then factory_source(base, nonce, random)
    when %r{\Aspec/support/} then support_source(base, nonce, random)
    when %r{\Aspec/features/} then feature_spec_source(base, nonce, random)
    when %r{\Aspec/lib/tasks/} then "RSpec.describe '#{base.delete_suffix('_spec')}' do\n  it('runs#{nonce}') {}\nend\n"
    when %r{\Aapp/graphql/} then graphql_source(relative, base, nonce)
    when %r{concerns/} then "module #{camelize(base)}\n  extend ActiveSupport::Concern\n  # #{nonce}\nend\n"
    when /_spec\.rb\z/ then "RSpec.describe Post do\n  it 'x#{nonce}' do\n    expect(Post).to be_a(Class)\n  end\nend\n"
    else "class #{camelize(base)}\n  VERSION = #{nonce}\n  def call\n    Post.count\n  end\nend\n"
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

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

  # `hlp_3_helper` defines `hlp_3_label`, the name the template artifacts call.
  def helper_module_source(base)
    "module #{camelize(base)}\n  def #{base.delete_suffix('_helper')}_label(value) = value\nend\n"
  end

  # Three shapes: a plain factory, one inheriting from another file's
  # factory (class resolved across files), and a definition file with no
  # factory, which is a test_support unit instead.
  def factory_source(base, nonce, random)
    case random.rand(4)
    when 0 then "FactoryBot.define do\n  after(:build) { |record| record.title ||= 'x#{nonce}' }\nend\n"
    when 1 then "FactoryBot.define do\n  factory :#{base}, parent: :fac_#{random.rand(6)} do\n  end\nend\n"
    when 2 then "FactoryBot.define do\n  factory :#{base}, class: '::Post' do\n    title { 'x#{nonce}' }\n  end\nend\n"
    else "FactoryBot.define do\n  factory :#{base} do\n    title { 'x#{nonce}' }\n  end\nend\n"
    end
  end

  # Names are keyed on a small slot number, not the file, so files collide on
  # names and specs refer to names that come and go.
  def support_source(base, nonce, random)
    slot = random.rand(4)
    case random.rand(4)
    when 0 then "RSpec.shared_examples 'shared #{slot}' do\n  it('n#{nonce}') {}\nend\n"
    when 1 then "RSpec.shared_context 'context #{slot}' do\n  let(:n) { #{nonce} }\nend\n"
    when 2 then "RSpec::Matchers.define :have_slot_#{slot} do |_|\n  match { |actual| actual == #{nonce} }\nend\n"
    else
      "module #{camelize(base)}Helpers\n  def helper_#{nonce} = true\nend\n" \
      "RSpec.configure { |c| c.include Slot#{slot}Helpers, type: :#{%w[feature request system][random.rand(3)]} }\n" \
      "module Slot#{slot}Helpers\nend\n"
    end
  end

  def feature_spec_source(base, nonce, random)
    slot = random.rand(4)
    <<~RUBY
      RSpec.feature '#{base} #{nonce}' do
        include Slot#{slot}Helpers
        include_context 'context #{slot}'
        it_behaves_like 'shared #{random.rand(4)}'
        scenario 'visits' do
          visit posts_path
          visit "/posts/\#{post.id}"
          visit '/comments'
          expect(page).to have_slot_#{slot}(1)
        end
      end
    RUBY
  end

  # Mentions artifacts from the other families by constant, path, task and
  # route, and links a sibling document. Which of them exist changes from one
  # operation to the next.
  def doc_source(base, nonce)
    a, b, c = nonce.digits.first(3).map { |digit| digit % 6 }.then { |digits| digits + ([0] * (3 - digits.size)) }
    <<~MARKDOWN
      # #{base} #{nonce}

      `Post` backs `Svc#{a}Service` and `Lb#{b}::VERSION`; see `app/services/svc_#{c}_service.rb`.
      More in [the next document](doc_#{b}.md) and [the model](../../app/models/post.rb).

      ## Operations

      ```
      bin/rake rk_#{a}:task0
      GET /posts
      Mgr#{c}Manager.new.call
      ```
    MARKDOWN
  end

  def migration_source(base, nonce)
    name = camelize(base.sub(/\A\d+_/, ''))
    "class #{name} < ActiveRecord::Migration[7.0]\n  def change\n    add_index :posts, :title # #{nonce}\n  end\nend\n"
  end

  def camelize(base)
    base.split('_').map(&:capitalize).join
  end
end
