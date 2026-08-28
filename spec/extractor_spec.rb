# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

RSpec.describe Woods::Extractor do
  # Use a real tmpdir so Pathname#exist? works without stubs.
  let(:tmpdir) { Dir.mktmpdir('woods_test') }
  let(:rails_root) { Pathname.new(tmpdir) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, 'output')) }

  # ── safe_eager_load! ────────────────────────────────────────────────

  describe '#safe_eager_load!' do
    let(:app_double) { double('Application') }

    before do
      allow(Rails).to receive(:application).and_return(app_double)
    end

    it 'calls eager_load! successfully when no error' do
      expect(app_double).to receive(:eager_load!).once
      expect(extractor).not_to receive(:eager_load_extraction_directories)

      extractor.send(:safe_eager_load!)
    end

    it 'falls back to per-directory loading on NameError' do
      expect(app_double).to receive(:eager_load!).and_raise(NameError.new('uninitialized constant GraphQL'))
      expect(extractor).to receive(:eager_load_extraction_directories)

      extractor.send(:safe_eager_load!)
    end

    it 'does not catch non-NameError exceptions' do
      expect(app_double).to receive(:eager_load!).and_raise(RuntimeError.new('something else'))

      expect { extractor.send(:safe_eager_load!) }.to raise_error(RuntimeError, 'something else')
    end
  end

  # ── eager_load_extraction_directories ────────────────────────────────

  describe '#eager_load_extraction_directories' do
    let(:loader) { double('Zeitwerk::Loader') }
    let(:autoloaders) { double('Autoloaders', main: loader) }

    before do
      allow(Rails).to receive(:autoloaders).and_return(autoloaders)
    end

    context 'with Zeitwerk 2.6+ (eager_load_dir available)' do
      before do
        allow(loader).to receive(:respond_to?).with(:eager_load_dir).and_return(true)
      end

      it 'calls eager_load_dir for existing directories' do
        # Create real directories
        FileUtils.mkdir_p(File.join(tmpdir, 'app', 'models'))
        FileUtils.mkdir_p(File.join(tmpdir, 'app', 'controllers'))

        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, 'app', 'models'))
        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, 'app', 'controllers'))

        extractor.send(:eager_load_extraction_directories)
      end

      it 'skips non-existent directories' do
        # Only create models, not controllers
        FileUtils.mkdir_p(File.join(tmpdir, 'app', 'models'))

        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, 'app', 'models'))
        # controllers dir doesn't exist, so no call expected

        extractor.send(:eager_load_extraction_directories)
      end

      it 'rescues NameError from individual directories and continues' do
        FileUtils.mkdir_p(File.join(tmpdir, 'app', 'models'))
        FileUtils.mkdir_p(File.join(tmpdir, 'app', 'controllers'))

        allow(loader).to receive(:eager_load_dir).with(File.join(tmpdir, 'app', 'models'))
                                                 .and_raise(NameError.new('bad constant'))
        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, 'app', 'controllers'))

        # Should not raise — error in models/ doesn't block controllers/
        expect { extractor.send(:eager_load_extraction_directories) }.not_to raise_error
      end
    end

    context 'with Zeitwerk 2.5 (no eager_load_dir)' do
      before do
        allow(loader).to receive(:respond_to?).with(:eager_load_dir).and_return(false)
      end

      it 'falls back to Dir.glob + require for existing directories' do
        models_dir = File.join(tmpdir, 'app', 'models')
        FileUtils.mkdir_p(models_dir)
        File.write(File.join(models_dir, 'user.rb'), '# user')
        File.write(File.join(models_dir, 'post.rb'), '# post')

        expect(extractor).to receive(:require).with(File.join(models_dir, 'post.rb')).ordered
        expect(extractor).to receive(:require).with(File.join(models_dir, 'user.rb')).ordered

        extractor.send(:eager_load_extraction_directories)
      end

      it 'rescues NameError from individual files and continues' do
        models_dir = File.join(tmpdir, 'app', 'models')
        FileUtils.mkdir_p(models_dir)
        File.write(File.join(models_dir, 'bad.rb'), '# bad')
        File.write(File.join(models_dir, 'good.rb'), '# good')

        allow(extractor).to receive(:require).with(File.join(models_dir, 'bad.rb'))
                                             .and_raise(NameError.new('uninitialized constant'))
        expect(extractor).to receive(:require).with(File.join(models_dir, 'good.rb'))

        expect { extractor.send(:eager_load_extraction_directories) }.not_to raise_error
      end
    end
  end

  # ── build_snapshot_store ──────────────────────────────────────────────

  describe '#build_snapshot_store' do
    before do
      require 'woods'
      Woods.configuration ||= Woods::Configuration.new
    end

    after do
      Woods.configuration = Woods::Configuration.new
    end

    it 'falls back to JsonSnapshotStore on LoadError' do
      allow(extractor).to receive(:require).with('sqlite3').and_raise(LoadError)

      store = extractor.send(:build_snapshot_store)
      expect(store).to be_a(Woods::Temporal::JsonSnapshotStore)
    end
  end

  # ── capture_snapshot ────────────────────────────────────────────────

  describe '#capture_snapshot' do
    before do
      require 'woods'
      Woods.configuration ||= Woods::Configuration.new
    end

    after do
      Woods.configuration = Woods::Configuration.new
    end

    it 'does nothing when enable_snapshots is false' do
      Woods.configuration.enable_snapshots = false
      expect(extractor).not_to receive(:build_snapshot_store)

      extractor.send(:capture_snapshot)
    end

    it 'rescues errors without aborting' do
      Woods.configuration.enable_snapshots = true

      # Set up a manifest file
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(output_dir)
      File.write(File.join(output_dir, 'manifest.json'), '{"git_sha":"abc123"}')

      allow(extractor).to receive(:build_snapshot_store).and_raise(StandardError, 'boom')
      extractor.instance_variable_set(:@results, {})

      expect { extractor.send(:capture_snapshot) }.not_to raise_error
    end

    it 'skips snapshotting when git_sha is unresolvable ("unknown") (#137)' do
      Woods.configuration.enable_snapshots = true

      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(output_dir)
      File.write(File.join(output_dir, 'manifest.json'), '{"git_sha":"unknown"}')

      # An "unknown" provenance must not key or collide a snapshot.
      expect(extractor).not_to receive(:build_snapshot_store)

      extractor.send(:capture_snapshot)
    end
  end

  # ── write_manifest — git provenance ─────────────────────────────────

  describe '#write_manifest' do
    # json_serialize reads Woods.configuration.pretty_json; ensure a config
    # exists regardless of suite ordering (another spec may have left it nil).
    # Requiring active_support's time ext defines Time.current so the stub below
    # is valid under verify_partial_doubles even when this file runs standalone
    # (`rake spec SPEC=...`), regardless of which other spec loaded it first.
    before do
      require 'woods'
      require 'active_support/core_ext/time'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
    end

    after do
      Woods.configuration = @original_config
    end

    it 'delegates branch/sha to a Rails.root-rooted GitProvenance (#137)' do
      allow(Rails).to receive(:version).and_return('7.1.0')
      # Stub Time.current (now defined by the require above) so the real one —
      # which needs ActiveSupport::IsolatedExecutionState / a loaded Time.zone —
      # is never invoked.
      allow(Time).to receive(:current).and_return(Time.now)
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(output_dir)
      extractor.instance_variable_set(:@results, {})

      provenance = instance_double(Woods::GitProvenance, to_h: { git_branch: 'unknown', git_sha: 'unknown' })
      expect(Woods::GitProvenance).to receive(:new).with(root: rails_root).and_return(provenance)

      extractor.send(:write_manifest)

      manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
      expect(manifest['git_branch']).to eq('unknown')
      expect(manifest['git_sha']).to eq('unknown')
    end

    it 'derives counts from persisted _index.json files in incremental mode, not the empty @results' do
      allow(Rails).to receive(:version).and_return('7.1.0')
      allow(Time).to receive(:current).and_return(Time.now)
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(File.join(output_dir, 'models'))
      FileUtils.mkdir_p(File.join(output_dir, 'controllers'))
      File.write(
        File.join(output_dir, 'models', '_index.json'),
        JSON.generate([{ identifier: 'User', chunk_count: 2 }, { identifier: 'Post', chunk_count: 1 }])
      )
      File.write(
        File.join(output_dir, 'controllers', '_index.json'),
        JSON.generate([{ identifier: 'UsersController', chunk_count: 3 }])
      )
      # Incremental runs never populate @results — the manifest must not zero out.
      extractor.instance_variable_set(:@results, {})

      provenance = instance_double(Woods::GitProvenance, to_h: { git_branch: 'main', git_sha: 'abc' })
      allow(Woods::GitProvenance).to receive(:new).and_return(provenance)

      extractor.send(:write_manifest, incremental: true)

      manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
      expect(manifest['counts']).to eq('models' => 2, 'controllers' => 1)
      expect(manifest['total_units']).to eq(3)
      expect(manifest['total_chunks']).to eq(6)
    end

    it 'still derives counts from @results in full mode' do
      allow(Rails).to receive(:version).and_return('7.1.0')
      allow(Time).to receive(:current).and_return(Time.now)
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(output_dir)
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.chunks = [{ chunk_index: 0 }]
      extractor.instance_variable_set(:@results, { models: [unit] })

      provenance = instance_double(Woods::GitProvenance, to_h: { git_branch: 'main', git_sha: 'abc' })
      allow(Woods::GitProvenance).to receive(:new).and_return(provenance)

      extractor.send(:write_manifest)

      manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
      expect(manifest['counts']).to eq('models' => 1)
      expect(manifest['total_units']).to eq(1)
      expect(manifest['total_chunks']).to eq(1)
    end
  end

  # ── extract_all phase ordering ──────────────────────────────────────

  describe '#extract_all flow precompute ordering' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.concurrent_extraction = false
      Woods.configuration.precompute_flows = true
    end

    after do
      Woods.configuration = @original_config
    end

    it 'precomputes flows only after write_results has written unit JSON to disk' do
      # FlowAssembler loads unit JSON from disk — precomputing before
      # write_results assembled every flow from absent or stale data.
      %i[setup_output_directory safe_eager_load! extract_all_sequential
         deduplicate_results resolve_dependents enrich_with_git_data
         normalize_file_paths write_dependency_graph write_graph_analysis
         write_manifest write_structural_summary capture_snapshot
         log_summary].each do |phase|
        allow(extractor).to receive(phase)
      end
      allow(Woods::ModelNameCache).to receive(:reset!)
      allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))

      expect(extractor).to receive(:write_results).ordered
      expect(extractor).to receive(:precompute_flows).ordered

      extractor.extract_all
    end
  end

  # ── rewrite_flow_annotated_units ────────────────────────────────────

  describe '#rewrite_flow_annotated_units' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
    end

    after do
      Woods.configuration = @original_config
    end

    it 're-writes units annotated with flow_paths and refreshes the type index' do
      output_dir = File.join(tmpdir, 'output')
      type_dir = File.join(output_dir, 'controllers')
      FileUtils.mkdir_p(type_dir)

      annotated = Woods::ExtractedUnit.new(
        type: :controller, identifier: 'OrdersController', file_path: 'app/controllers/orders_controller.rb'
      )
      annotated.metadata = { flow_paths: { 'create' => 'flows/OrdersController_create.json' } }
      plain = Woods::ExtractedUnit.new(
        type: :controller, identifier: 'UsersController', file_path: 'app/controllers/users_controller.rb'
      )
      extractor.instance_variable_set(:@results, { controllers: [annotated, plain] })

      extractor.send(:rewrite_flow_annotated_units)

      written = Dir[File.join(type_dir, '*.json')].reject { |f| File.basename(f) == '_index.json' }
      expect(written.size).to eq(1)
      unit_json = JSON.parse(File.read(written.first))
      expect(unit_json['identifier']).to eq('OrdersController')
      expect(unit_json.dig('metadata', 'flow_paths', 'create')).to eq('flows/OrdersController_create.json')

      # The refreshed index is built from the in-memory @results (both
      # units), not from the on-disk files (only the annotated one was
      # rewritten here) — matching what write_results emitted for this type.
      index = JSON.parse(File.read(File.join(type_dir, '_index.json')))
      expect(index.map { |e| e['identifier'] }).to eq(%w[OrdersController UsersController])
    end

    it 'refreshes the type index from @results, not a disk glob (no stale-unit resurrection)' do
      output_dir = File.join(tmpdir, 'output')
      type_dir = File.join(output_dir, 'controllers')
      FileUtils.mkdir_p(type_dir)

      # A stale unit file from a previous run for a controller since deleted
      # from the app. It is NOT present in @results.
      File.write(
        File.join(type_dir, 'DeletedController_abc1.json'),
        JSON.generate(identifier: 'DeletedController', file_path: 'x', namespace: nil, chunks: [])
      )

      annotated = Woods::ExtractedUnit.new(
        type: :controller, identifier: 'OrdersController', file_path: 'app/controllers/orders_controller.rb'
      )
      annotated.metadata = { flow_paths: { 'create' => 'flows/OrdersController_create.json' } }
      extractor.instance_variable_set(:@results, { controllers: [annotated] })

      extractor.send(:rewrite_flow_annotated_units)

      index = JSON.parse(File.read(File.join(type_dir, '_index.json')))
      # The deleted controller's stale file must NOT be resurrected into the index.
      expect(index.map { |e| e['identifier'] }).to eq(['OrdersController'])
    end

    it 'does nothing when no unit carries flow_paths' do
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(File.join(output_dir, 'controllers'))
      plain = Woods::ExtractedUnit.new(
        type: :controller, identifier: 'UsersController', file_path: 'app/controllers/users_controller.rb'
      )
      extractor.instance_variable_set(:@results, { controllers: [plain] })

      extractor.send(:rewrite_flow_annotated_units)

      expect(Dir[File.join(output_dir, 'controllers', '*.json')]).to be_empty
    end
  end

  # ── regenerate_type_index ───────────────────────────────────────────

  describe '#regenerate_type_index' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
    end

    after do
      Woods.configuration = @original_config
    end

    it 'recomputes estimated_tokens from unit JSON instead of indexing null' do
      output_dir = File.join(tmpdir, 'output')
      type_dir = File.join(output_dir, 'models')
      FileUtils.mkdir_p(type_dir)
      # Unit JSON as written by ExtractedUnit#to_h — no estimated_tokens key.
      File.write(
        File.join(type_dir, 'User.json'),
        JSON.generate(
          identifier: 'User',
          file_path: 'app/models/user.rb',
          namespace: nil,
          source_code: 'x' * 40,
          metadata: {},
          chunks: [{ chunk_index: 0 }]
        )
      )

      extractor.send(:regenerate_type_index, :models)

      index = JSON.parse(File.read(File.join(type_dir, '_index.json')))
      expect(index.size).to eq(1)
      expect(index.first['estimated_tokens']).to eq(10) # 40 chars / 4.0
      expect(index.first['chunk_count']).to eq(1)
    end
  end

  # ── extract_all_concurrent — warning survival ──────────────────────

  describe '#extract_all_concurrent' do
    before do
      require 'woods'
      # The extraction threads call Time.current for timing logs. In a Rails
      # host it's always defined, but in this suite it only works if another
      # spec happened to load the exts first — require them here so this
      # example doesn't depend on suite ordering (the thread's rescue would
      # otherwise swallow the NameError and @extractors would never be
      # populated). isolated_execution_state backs Time.zone, which
      # Time.current consults before falling back to Time.now.
      require 'active_support/isolated_execution_state'
      require 'active_support/core_ext/time'
      Woods.configuration ||= Woods::Configuration.new
      Woods.configuration.concurrent_extraction = true
    end

    after do
      Woods.configuration = Woods::Configuration.new
    end

    it 'preserves extractor instance for warning collection when extract_all fails' do
      # Create a fake extractor class whose extract_all raises
      fake_class = Class.new do
        attr_reader :warnings

        def initialize
          @warnings = ['pre-existing warning']
        end

        def extract_all
          raise StandardError, 'boom'
        end
      end

      # Stub EXTRACTORS to only have our fake
      stub_const('Woods::Extractor::EXTRACTORS', { test_type: fake_class })

      # Stub ModelNameCache
      model_name_cache = double('ModelNameCache')
      allow(model_name_cache).to receive(:model_names)
      allow(model_name_cache).to receive(:model_names_regex)
      stub_const('Woods::ModelNameCache', model_name_cache)

      expect { extractor.send(:extract_all_concurrent) }.to raise_error(Woods::ExtractionError)

      stored_extractor = extractor.instance_variable_get(:@extractors)[:test_type]
      expect(stored_extractor).not_to be_nil
      expect(stored_extractor.warnings).to include('pre-existing warning')
    end

    # A failing thread used to substitute `[]` into @results and let the run
    # finish normally — a partial generation published as though every type
    # had actually extracted. Fail closed instead: name the failure and never
    # reach dependency-graph registration (the step write_results/publish_generation
    # depend on) for that run.
    it 'raises naming the failed type instead of silently substituting empty results' do
      fake_class = Class.new do
        def extract_all
          raise StandardError, 'boom'
        end
      end
      ok_class = Class.new do
        def extract_all
          []
        end
      end
      stub_const('Woods::Extractor::EXTRACTORS', { broken_type: fake_class, fine_type: ok_class })

      model_name_cache = double('ModelNameCache')
      allow(model_name_cache).to receive(:model_names)
      allow(model_name_cache).to receive(:model_names_regex)
      stub_const('Woods::ModelNameCache', model_name_cache)

      expect { extractor.send(:extract_all_concurrent) }
        .to raise_error(Woods::ExtractionError, /broken_type/)

      # Nothing was registered into the graph for this run — a partial result
      # never reaches the write/publish phase that would otherwise ship it.
      expect(extractor.instance_variable_get(:@dependency_graph).to_h[:nodes]).to be_empty
    end

    it 'does not reach write_results or publish_generation when a thread fails' do
      fake_class = Class.new do
        def extract_all
          raise StandardError, 'boom'
        end
      end
      stub_const('Woods::Extractor::EXTRACTORS', { broken_type: fake_class })

      model_name_cache = double('ModelNameCache')
      allow(model_name_cache).to receive(:reset!)
      allow(model_name_cache).to receive(:model_names)
      allow(model_name_cache).to receive(:model_names_regex)
      stub_const('Woods::ModelNameCache', model_name_cache)

      allow(extractor).to receive(:setup_output_directory)
      allow(extractor).to receive(:safe_eager_load!)
      expect(extractor).not_to receive(:write_results)
      expect(extractor).not_to receive(:publish_generation)

      expect { extractor.extract_all }.to raise_error(Woods::ExtractionError, /broken_type/)
    end
  end

  # ── json_serialize ───────────────────────────────────────────────────

  describe '#json_serialize' do
    before do
      require 'woods'
      Woods.configuration ||= Woods::Configuration.new
    end

    after do
      Woods.configuration = Woods::Configuration.new
    end

    it 'returns pretty JSON when pretty_json is true' do
      Woods.configuration.pretty_json = true
      output = extractor.send(:json_serialize, { key: 'value' })
      expect(output).to include("\n")
    end

    it 'returns compact JSON when pretty_json is false' do
      Woods.configuration.pretty_json = false
      output = extractor.send(:json_serialize, { key: 'value' })
      expect(output).not_to include("\n")
    end
  end

  # ── schema_sha ─────────────────────────────────────────────────────

  describe '#schema_sha' do
    it 'returns SHA for db/schema.rb when it exists' do
      FileUtils.mkdir_p(File.join(tmpdir, 'db'))
      File.write(File.join(tmpdir, 'db', 'schema.rb'), 'ActiveRecord::Schema.define {}')

      result = extractor.send(:schema_sha)
      expect(result).to match(/\A[a-f0-9]{64}\z/)
    end

    it 'falls back to db/structure.sql when schema.rb does not exist' do
      FileUtils.mkdir_p(File.join(tmpdir, 'db'))
      File.write(File.join(tmpdir, 'db', 'structure.sql'), 'CREATE TABLE users;')

      result = extractor.send(:schema_sha)
      expect(result).to match(/\A[a-f0-9]{64}\z/)
    end

    it 'prefers schema.rb over structure.sql when both exist' do
      FileUtils.mkdir_p(File.join(tmpdir, 'db'))
      File.write(File.join(tmpdir, 'db', 'schema.rb'), 'schema content')
      File.write(File.join(tmpdir, 'db', 'structure.sql'), 'structure content')

      expected = Digest::SHA256.hexdigest('schema content')
      result = extractor.send(:schema_sha)
      expect(result).to eq(expected)
    end

    it 'returns nil when neither file exists' do
      result = extractor.send(:schema_sha)
      expect(result).to be_nil
    end
  end

  # ── batch_git_data ───────────────────────────────────────────────────

  describe '#batch_git_data' do
    it 'returns empty hash for empty input' do
      expect(extractor.send(:batch_git_data, [])).to eq({})
    end

    it 'batches paths in slices of 500 to avoid ARG_MAX' do
      require 'active_support'
      require 'active_support/core_ext/numeric/time'

      file_paths = (1..1100).map { |i| File.join(tmpdir, "file_#{i}.rb") }

      allow(extractor).to receive(:parse_git_log_output)
      allow(extractor).to receive(:build_file_metadata).and_return({})

      # Stub Time.current to return a time that supports ActiveSupport duration arithmetic
      fake_now = Time.new(2024, 1, 1, 0, 0, 0, '+00:00')
      allow(Time).to receive(:current).and_return(fake_now)

      # run_git should be called once per slice: ceil(1100 / 500) = 3 (500, 500, 100)
      expect(extractor).to receive(:run_git).exactly(3).times.and_return('')

      extractor.send(:batch_git_data, file_paths)
    end
  end

  # ── re_extract_unit ───────────────────────────────────────────────────

  describe '#re_extract_unit' do
    it 'skips constantize for unit_id not matching Ruby constant format' do
      # Inject a fake node with a CLASS_BASED type so we reach the constantize branch
      node = { type: 'model', file_path: File.join(tmpdir, 'user.rb') }
      FileUtils.touch(File.join(tmpdir, 'user.rb'))

      graph = extractor.instance_variable_get(:@dependency_graph)
      allow(graph).to receive(:node).with('../malicious/path').and_return(node)

      # constantize must NOT be called for an invalid identifier
      expect_any_instance_of(String).not_to receive(:constantize)

      extractor.send(:re_extract_unit, '../malicious/path')
    end

    it 'allows constantize for valid Ruby constant identifiers' do
      node = { type: 'model', file_path: File.join(tmpdir, 'user.rb') }
      FileUtils.touch(File.join(tmpdir, 'user.rb'))

      graph = extractor.instance_variable_get(:@dependency_graph)
      allow(graph).to receive(:node).with('User').and_return(node)

      extractor_double = double('ModelExtractor')
      allow(Woods::Extractors::ModelExtractor).to receive(:new).and_return(extractor_double)

      # constantize raises NameError (no Rails env) — that's fine, it just returns nil
      # The important thing is no error from the format check itself
      expect { extractor.send(:re_extract_unit, 'User') }.not_to raise_error
    end

    it 'registers and writes every unit when a file-based extractor returns multiple units' do
      # A single .rake file defines multiple tasks, so extract_rake_file returns
      # an Array of units. re_extract_unit must fan out over them, not pass the
      # Array straight to DependencyGraph#register.
      require 'woods' # defines Woods.configuration (json_serialize reads pretty_json)
      Woods.configuration ||= Woods::Configuration.new

      rake_path = File.join(tmpdir, 'things.rake')
      FileUtils.touch(rake_path)
      # The type dir exists in real usage (created by the initial full extraction).
      rake_dir = File.join(tmpdir, 'output', 'rake_tasks')
      FileUtils.mkdir_p(rake_dir)

      node = { type: :rake_task, file_path: rake_path }
      graph = extractor.instance_variable_get(:@dependency_graph)
      allow(graph).to receive(:node_types).with('things:one').and_return([:rake_task])
      allow(graph).to receive(:node).with('things:one', type: :rake_task).and_return(node)
      allow(graph).to receive(:register).and_call_original

      unit_one = Woods::ExtractedUnit.new(type: :rake_task, identifier: 'things:one', file_path: rake_path)
      unit_two = Woods::ExtractedUnit.new(type: :rake_task, identifier: 'things:two', file_path: rake_path)

      rake_extractor = instance_double(Woods::Extractors::RakeTaskExtractor)
      allow(Woods::Extractors::RakeTaskExtractor).to receive(:new).and_return(rake_extractor)
      allow(rake_extractor).to receive(:extract_rake_file).with(rake_path).and_return([unit_one, unit_two])

      expect { extractor.send(:re_extract_unit, 'things:one') }.not_to raise_error

      expect(graph).to have_received(:register).with(unit_one)
      expect(graph).to have_received(:register).with(unit_two)

      expect(File.exist?(File.join(rake_dir, extractor.send(:collision_safe_filename, 'things:one')))).to be(true)
      expect(File.exist?(File.join(rake_dir, extractor.send(:collision_safe_filename, 'things:two')))).to be(true)
    end
  end

  # ── reconcile_changed_paths — failed extractor construction (#198) ──

  # `extractor_for` rescues a raising *constructor* and memoizes nil, and nil
  # fails `extract_with_rule`'s respond_to? guard — which used to answer []:
  # the "this path defines nothing any more" answer that licenses
  # `prune_path_leftovers`. So one broken constructor (a DB connection down, a
  # route-helper map that raised) deleted every previously-registered unit on
  # every changed path of that type, and the run bumped the generation over
  # the loss. Construction failure and "extracted successfully, defines
  # nothing" are different answers; only the second may prune.
  describe '#reconcile_changed_paths when an extractor cannot be constructed' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      allow(Woods::Extractors::ServiceExtractor).to receive(:new)
        .and_raise(StandardError, 'no database connection')
    end

    after { Woods.configuration = @original_config }

    let(:service_path) { File.join(tmpdir, 'app/services/billing_service.rb') }
    let(:service_rule) { Woods::PathDispatcher.new.file_rules_for('app/services/billing_service.rb').fetch(0) }

    it 'does not prune the units previously registered on the changed path' do
      FileUtils.mkdir_p(File.dirname(service_path))
      File.write(service_path, 'class BillingService; end')
      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: :service, identifier: 'BillingService', file_path: service_path)
      )

      extractor.send(:reconcile_changed_paths,
                     Woods::ChangeSet.new(paths: ['app/services/billing_service.rb'], root: rails_root),
                     Set.new)

      expect(extractor.dependency_graph.node_exists?('BillingService')).to be(true)
    end

    it 'returns nil from extract_with_rule — "tells us nothing", not "defines nothing"' do
      expect(extractor.send(:extract_with_rule, service_rule, service_path)).to be_nil
    end

    it 'still returns [] for a genuinely constructed extractor lacking the rule method' do
      # Seeding the memo hash sidesteps construction, as the reconcile specs
      # do. An instance without the method IS the "defines nothing" answer.
      extractor.instance_variable_set(:@incremental_extractors, { services: Object.new })

      expect(extractor.send(:extract_with_rule, service_rule, service_path)).to eq([])
    end
  end

  # ── refresh ──────────────────────────────────────────────────────────

  describe '#refresh' do
    before do
      require 'woods'
      # Time.current and Rails.version are reached through write_manifest;
      # see the #write_manifest context for why the require + stub are needed.
      require 'active_support/core_ext/time'
      allow(Time).to receive(:current).and_return(Time.now)
      allow(Rails).to receive(:version).and_return('8.0.0')
      allow(Rails).to receive(:application).and_return(double('Application', eager_load!: nil))
      allow(Woods::ModelNameCache).to receive(:reset!)
      FileUtils.mkdir_p(File.join(tmpdir, 'output'))
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
    end

    after { Woods.configuration = @original_config }

    # Stub the named extractors, plus the route consumers a routes refresh
    # cascades to — those instantiate against a live route table, which this
    # unit-level context has no business booting.
    def stub_extractor(key, units)
      cascaded = described_class::ROUTE_CONSUMER_EXTRACTORS.to_h do |consumer|
        [consumer, double(new: double("#{consumer}Extractor", extract_all: []))]
      end
      stubbed = cascaded.merge(key => double(new: double("#{key}Extractor", extract_all: units)))

      stub_const('Woods::Extractor::EXTRACTORS', described_class::EXTRACTORS.merge(stubbed))
    end

    def unit(type:, identifier:)
      Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil)
    end

    it 'runs the named extractor and reports what it touched' do
      stub_extractor(:routes, [unit(type: :route, identifier: 'GET /posts')])

      result = extractor.refresh(:routes)

      expect(result[:types]).to include(:routes)
      expect(result[:touched]).to include('GET /posts')
    end

    it 'accepts strings as well as symbols' do
      stub_extractor(:middleware, [unit(type: :middleware, identifier: 'MiddlewareStack')])

      expect(extractor.refresh('middleware')[:types]).to eq([:middleware])
    end

    it 'replaces the type wholesale, dropping units the fresh run no longer produces' do
      graph = extractor.dependency_graph
      graph.register(unit(type: :route, identifier: 'GET /gone'))
      stub_extractor(:routes, [unit(type: :route, identifier: 'GET /posts')])

      result = extractor.refresh(:routes)

      expect(result[:touched]).to include('GET /gone')
      expect(graph.node_exists?('GET /gone')).to be(false)
      expect(graph.node_exists?('GET /posts')).to be(true)
    end

    # Controllers and friends embed the route table, so refreshing routes
    # without them would leave their metadata describing the old route set.
    it 'cascades a routes refresh to the extractors that embed the route table' do
      stub_extractor(:routes, [])

      expect(extractor.refresh(:routes)[:types]).to include(*described_class::ROUTE_CONSUMER_EXTRACTORS)
    end

    it 'reports unknown keys instead of failing when at least one is known' do
      stub_extractor(:routes, [])

      result = extractor.refresh(:routes, :not_an_extractor)

      expect(result[:unknown]).to eq([:not_an_extractor])
      expect(result[:types]).to include(:routes)
    end

    it 'raises when no key is recognized' do
      expect { extractor.refresh(:nonsense) }.to raise_error(ArgumentError, /No known extractor/)
    end

    it 'writes the dependency graph so the refresh is durable' do
      stub_extractor(:routes, [unit(type: :route, identifier: 'GET /posts')])

      extractor.refresh(:routes)

      index_dir = File.join(tmpdir, 'output')
      payload = JSON.parse(File.read(File.join(index_dir, 'generation.json')))['payload']
      graph = JSON.parse(File.read(File.join(index_dir, payload, 'dependency_graph.json')))
      expect(graph['nodes']).to have_key('GET /posts')
    end
  end

  # ── replace_type_wholesale — removal gate (#198) ─────────────────────

  # {#stale_class_based_units} opens with `return [] unless
  # @eager_load_complete` — documented as the whole safety argument — but
  # replace_type_wholesale performed the same discovery-set-driven removal
  # with no gate at all. For the CLASS_BASED_DISCOVERY extractors,
  # `extract_all` is a function of the runtime descendants, so on the
  # NameError-fallback boot the fresh set is known-partial — and
  # ROUTE_CONSUMER_EXTRACTORS routes four such types through here on every
  # routes change, so one routes edit mass-deleted most controller units.
  describe '#replace_type_wholesale removal gate' do
    let(:fresh_unit) do
      Woods::ExtractedUnit.new(type: :controller, identifier: 'PostsController', file_path: nil)
    end
    let(:fake_controllers) { double('ControllerExtractor', extract_all: [fresh_unit]) }

    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      FileUtils.mkdir_p(File.join(tmpdir, 'output'))
      # extractor_for memoizes into this hash, so seeding it injects the
      # double without booting a real extractor against no Rails app.
      extractor.instance_variable_set(:@incremental_extractors, { controllers: fake_controllers })
      register(type: :controller, identifier: 'PostsController')
      register(type: :controller, identifier: 'GoneController')
    end

    after { Woods.configuration = @original_config }

    def register(type:, identifier:)
      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil)
      )
    end

    def replace(key)
      extractor.send(:replace_type_wholesale, key, Set.new)
    end

    context 'when the eager load fell back to per-directory loading' do
      before { extractor.instance_variable_set(:@eager_load_complete, false) }

      it 'does not remove class-based units absent from the partial discovery set' do
        replace(:controllers)

        expect(extractor.dependency_graph.node_exists?('GoneController')).to be(true)
        expect(extractor.dependency_graph.node_exists?('PostsController')).to be(true)
      end

      it 'warns that the type may hold stale units until a clean boot' do
        expect(Rails.logger).to receive(:warn).with(/Skipping stale-unit removal for controllers/)

        replace(:controllers)
      end

      # Routes, view_templates and friends glob files or introspect the live
      # route table — their extract_all does not depend on eager loading, so
      # their fresh set stays authoritative on any boot.
      it 'still removes stale units of file-derived whole-app types' do
        register(type: :route, identifier: 'GET /gone')
        extractor.instance_variable_get(:@incremental_extractors)[:routes] =
          double('RoutesExtractor', extract_all: [])

        expect(replace(:routes)).to include('GET /gone')
        expect(extractor.dependency_graph.node_exists?('GET /gone')).to be(false)
      end
    end

    context 'when the eager load was complete' do
      before { extractor.instance_variable_set(:@eager_load_complete, true) }

      it 'removes units the fresh run no longer produces (existing behavior pinned)' do
        expect(replace(:controllers)).to include('GoneController')
        expect(extractor.dependency_graph.node_exists?('GoneController')).to be(false)
        expect(extractor.dependency_graph.node_exists?('PostsController')).to be(true)
      end

      it 'does not warn' do
        expect(Rails.logger).not_to receive(:warn)

        replace(:controllers)
      end
    end
  end

  # ── rails_source as a whole-app extractor (#169) ─────────────────────

  # Framework sources were only ever written by `woods:extract_framework`,
  # which bypassed the whole write pipeline. Making rails_source a
  # Gemfile.lock-keyed whole-app extractor routes it through
  # replace_type_wholesale like routes/middleware — which only works if
  # EVERY type the extractor emits is mapped (the CLAUDE.md GraphQL history
  # is what happens otherwise).
  describe 'rails_source whole-app wiring (#169)' do
    it 'maps both emitted unit types back to the rails_source extractor' do
      expect(described_class::EXTRACTOR_KEY_TO_TYPES[:rails_source])
        .to contain_exactly(:rails_source, :gem_source)
    end

    it 'registers rails_source among the whole-app extractors' do
      expect(described_class::WHOLE_APP_EXTRACTORS).to have_key(:rails_source)
    end
  end

  describe '#replace_type_wholesale for rails_source (#169)' do
    let(:stale_gem_id) { 'gems/devise/lib/devise/models.rb' }
    let(:fresh_unit) do
      Woods::ExtractedUnit.new(
        type: :rails_source, identifier: 'rails/activerecord/lib/active_record/enum.rb', file_path: nil
      )
    end
    let(:fake_rails_source) { double('RailsSourceExtractor', extract_all: [fresh_unit]) }
    let(:type_dir) { File.join(tmpdir, 'output', 'rails_source') }

    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      FileUtils.mkdir_p(type_dir)
      extractor.instance_variable_set(:@incremental_extractors, { rails_source: fake_rails_source })

      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: :gem_source, identifier: stale_gem_id, file_path: nil)
      )
      # The stale unit's JSON, as a previous run wrote it into rails_source/
      # (gem_source units share the extractor's directory).
      File.write(
        File.join(type_dir, extractor.send(:collision_safe_filename, stale_gem_id)),
        JSON.generate(identifier: stale_gem_id)
      )
    end

    after { Woods.configuration = @original_config }

    # rails_source is NOT in CLASS_BASED_DISCOVERY — its extract_all globs
    # installed gem files, not runtime descendants — so removal is
    # unconditional regardless of @eager_load_complete, like routes.
    it 'prunes a stale gem_source unit, JSON file included, when replacing the type' do
      removed = extractor.send(:replace_type_wholesale, :rails_source, Set.new)

      expect(removed).to include(stale_gem_id)
      expect(extractor.dependency_graph.node_exists?(stale_gem_id)).to be(false)
      expect(File.exist?(File.join(type_dir, extractor.send(:collision_safe_filename, stale_gem_id))))
        .to be(false)
    end

    it 'writes the fresh units through the pipeline into the rails_source directory' do
      extractor.send(:replace_type_wholesale, :rails_source, Set.new)

      expect(extractor.dependency_graph.node_exists?(fresh_unit.identifier)).to be(true)
      fresh_file = File.join(type_dir, extractor.send(:collision_safe_filename, fresh_unit.identifier))
      expect(JSON.parse(File.read(fresh_file))['identifier']).to eq(fresh_unit.identifier)
    end
  end

  describe '#rerun_whole_app_extractors include_framework_sources gate (#169)' do
    let(:framework_unit) do
      Woods::ExtractedUnit.new(
        type: :rails_source, identifier: 'rails/activerecord/lib/active_record/enum.rb', file_path: nil
      )
    end
    let(:fake_rails_source) { double('RailsSourceExtractor', extract_all: [framework_unit]) }
    let(:fake_engines) { double('EngineExtractor', extract_all: []) }
    let(:fake_middleware) { double('MiddlewareExtractor', extract_all: []) }

    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      FileUtils.mkdir_p(File.join(tmpdir, 'output'))
      extractor.instance_variable_set(
        :@incremental_extractors,
        { rails_source: fake_rails_source, engines: fake_engines, middleware: fake_middleware }
      )
    end

    after { Woods.configuration = @original_config }

    def rerun(paths)
      extractor.send(:rerun_whole_app_extractors,
                     Woods::ChangeSet.new(paths: paths, root: rails_root),
                     Set.new)
    end

    it 'replaces framework sources through the pipeline when Gemfile.lock changes' do
      touched = rerun(['Gemfile.lock'])

      expect(touched).to include(framework_unit.identifier)
      expect(extractor.dependency_graph.node_exists?(framework_unit.identifier)).to be(true)
      expect(Dir[File.join(tmpdir, 'output', 'rails_source', '*.json')]).not_to be_empty
    end

    # An ungated dispatch rule with a gated extractor must not manufacture a
    # phantom `touched` cycle: with the knob off, a lockfile change re-runs
    # everything Gemfile.lock legitimately triggers — except rails_source.
    it 'does not re-run rails_source when include_framework_sources is off' do
      Woods.configuration.include_framework_sources = false

      touched = rerun(['Gemfile.lock'])

      expect(fake_rails_source).not_to have_received(:extract_all)
      expect(fake_engines).to have_received(:extract_all)
      expect(fake_middleware).to have_received(:extract_all)
      expect(touched).not_to include(framework_unit.identifier)
    end
  end

  # The documented default for include_framework_sources is `true`
  # (docs/CONFIGURATION_REFERENCE.md), so full runs keep extracting framework
  # sources unless the host opts out — wiring the knob changes nothing for
  # existing hosts.
  describe 'full extraction include_framework_sources gate (#169)' do
    let(:fake_extractor_class) do
      Class.new do
        def extract_all
          []
        end
      end
    end

    before do
      require 'woods'
      require 'active_support/isolated_execution_state'
      require 'active_support/core_ext/time'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      stub_const('Woods::Extractor::EXTRACTORS',
                 { rails_source: fake_extractor_class, routes: fake_extractor_class })
    end

    after { Woods.configuration = @original_config }

    it 'defaults to including framework sources — the documented default is true' do
      expect(Woods::Configuration.new.include_framework_sources).to be(true)

      extractor.send(:extract_all_sequential)

      expect(extractor.instance_variable_get(:@results)).to have_key(:rails_source)
    end

    it 'skips the rails_source extractor when the knob is off (sequential)' do
      Woods.configuration.include_framework_sources = false

      extractor.send(:extract_all_sequential)

      results = extractor.instance_variable_get(:@results)
      expect(results).not_to have_key(:rails_source)
      expect(results).to have_key(:routes)
    end

    it 'skips the rails_source extractor when the knob is off (concurrent)' do
      Woods.configuration.include_framework_sources = false
      model_name_cache = double('ModelNameCache')
      allow(model_name_cache).to receive_messages(model_names: nil, model_names_regex: nil)
      stub_const('Woods::ModelNameCache', model_name_cache)

      extractor.send(:extract_all_concurrent)

      results = extractor.instance_variable_get(:@results)
      expect(results).not_to have_key(:rails_source)
      expect(results).to have_key(:routes)
    end
  end

  # ── extract_all orphan sweep (#177) ──────────────────────────────────

  # A full extraction never wipes the output directory, so extracting into a
  # directory that saw a different version of the app left the previous run's
  # unit files in place. The freshly-written _index.json and manifest were
  # correct — but the NEXT incremental run's regenerate_type_index rebuilds
  # the index from a disk glob of the type dir, resurrecting every orphan into
  # the listed index, and persisted_counts then wrote the inflated counts into
  # the manifest. On a full run the in-memory @results are authoritative (the
  # argument rewrite_flow_annotated_units already makes), so anything they do
  # not account for is swept.
  describe 'full extraction orphan sweep (#177)' do
    let(:output_dir) { File.join(tmpdir, 'output') }
    let(:models_dir) { File.join(output_dir, 'models') }
    let(:rails_source_dir) { File.join(output_dir, 'rails_source') }

    # Seeds go into the flat output root; a run clones it into the payload it
    # publishes, so assertions resolve through the pointer the way a reader
    # does rather than assuming a layout.
    def payload_root
      marker = File.join(output_dir, 'generation.json')
      return output_dir unless File.exist?(marker)

      name = JSON.parse(File.read(marker))['payload']
      name ? File.join(output_dir, name) : output_dir
    end

    def published_models_dir
      File.join(payload_root, 'models')
    end

    def published_rails_source_dir
      File.join(payload_root, 'rails_source')
    end
    let(:framework_id) { 'rails/activerecord/lib/active_record/enum.rb' }

    let(:current_unit) do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.source_code = 'class User; end'
      unit
    end

    let(:fake_models_class) do
      unit = current_unit
      Class.new { define_method(:extract_all) { [unit] } }
    end

    let(:fake_empty_class) do
      Class.new do
        def extract_all
          []
        end
      end
    end

    before do
      require 'woods'
      # extract_all runs the whole write pipeline: Time.current (timing logs +
      # manifest), Rails.version (manifest), titleize (SUMMARY.md). Require and
      # stub so the examples don't depend on suite ordering — see the
      # #write_manifest context for the pattern.
      require 'active_support'
      require 'active_support/isolated_execution_state'
      require 'active_support/core_ext/time'
      require 'active_support/core_ext/string/inflections'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.concurrent_extraction = false
      allow(Time).to receive(:current).and_return(Time.now)
      allow(Rails).to receive(:version).and_return('8.0.0')
      allow(extractor).to receive(:safe_eager_load!)
      allow(extractor).to receive(:git_available?).and_return(false)
      stub_const('Woods::Extractor::EXTRACTORS',
                 { models: fake_models_class, rails_source: fake_empty_class })
    end

    after { Woods.configuration = @original_config }

    def seed_unit_file(dir, filename, identifier)
      FileUtils.mkdir_p(dir)
      File.write(
        File.join(dir, filename),
        JSON.generate(identifier: identifier, file_path: 'x', namespace: nil,
                      source_code: '', metadata: {}, chunks: [])
      )
    end

    def filename_for(identifier)
      extractor.send(:collision_safe_filename, identifier)
    end

    it 'removes stale unit files of both name shapes while keeping the current units and _index.json' do
      seed_unit_file(models_dir, filename_for('Ghost'), 'Ghost') # current (digest) shape
      seed_unit_file(models_dir, 'Legacy.json', 'Legacy')        # legacy safe_filename shape
      seed_unit_file(models_dir, 'User.json', 'User')            # legacy name of a CURRENT unit — still an orphan

      extractor.extract_all

      expect(File.exist?(File.join(published_models_dir, filename_for('User')))).to be(true)
      expect(File.exist?(File.join(published_models_dir, filename_for('Ghost')))).to be(false)
      expect(File.exist?(File.join(published_models_dir, 'Legacy.json'))).to be(false)
      expect(File.exist?(File.join(published_models_dir, 'User.json'))).to be(false)

      index = JSON.parse(File.read(File.join(published_models_dir, '_index.json')))
      expect(index.map { |e| e['identifier'] }).to eq(['User'])
      expect(File.exist?(File.join(payload_root, 'manifest.json'))).to be(true)
    end

    it 'touches only *.json inside the type dirs — never non-JSON files or the output root' do
      seed_unit_file(models_dir, filename_for('Ghost'), 'Ghost')
      File.write(File.join(published_models_dir, 'notes.txt'), 'not woods output')
      FileUtils.mkdir_p(File.join(output_dir, 'dumps'))
      File.write(File.join(output_dir, 'dumps', 'stale_vector.json'), '{}')
      File.write(File.join(output_dir, 'woods.json'), '{}')

      extractor.extract_all

      expect(File.exist?(File.join(published_models_dir, 'notes.txt'))).to be(true)
      expect(File.exist?(File.join(published_models_dir, '_index.json'))).to be(true)
      expect(File.exist?(File.join(output_dir, 'dumps', 'stale_vector.json'))).to be(true)
      expect(File.exist?(File.join(output_dir, 'woods.json'))).to be(true)
    end

    # #169: `woods:extract_framework` writes framework units on demand for
    # knob-off hosts. A knob-off full run produces no :rails_source key in
    # @results, so its directory must not be entered at all.
    it 'leaves the rails_source directory untouched when include_framework_sources is off' do
      Woods.configuration.include_framework_sources = false
      seed_unit_file(rails_source_dir, filename_for(framework_id), framework_id)

      extractor.extract_all

      expect(File.exist?(File.join(published_rails_source_dir, filename_for(framework_id)))).to be(true)
    end

    # The gate is the @results key, not the type name: with the knob on, the
    # run produced (an empty) rails_source and its stale files are orphans
    # like any other type's.
    it 'sweeps rails_source like any other produced type when the knob is on' do
      seed_unit_file(rails_source_dir, filename_for(framework_id), framework_id)

      extractor.extract_all

      expect(File.exist?(File.join(published_rails_source_dir, filename_for(framework_id)))).to be(false)
    end

    it 'sweeps under concurrent extraction too' do
      Woods.configuration.concurrent_extraction = true
      model_name_cache = double('ModelNameCache')
      allow(model_name_cache).to receive_messages(reset!: nil, model_names: [], model_names_regex: /(?!)/,
                                                  short_name_map: {}, short_names_regex: /(?!)/)
      stub_const('Woods::ModelNameCache', model_name_cache)
      seed_unit_file(models_dir, 'Legacy.json', 'Legacy')

      extractor.extract_all

      expect(File.exist?(File.join(published_models_dir, 'Legacy.json'))).to be(false)
      expect(File.exist?(File.join(published_models_dir, filename_for('User')))).to be(true)
    end

    # The worsening half of #177, end to end: before the sweep, the orphan the
    # full run left behind was resurrected into _index.json by the next
    # incremental run's disk-glob rebuild, and persisted_counts then inflated
    # the manifest with it. After the sweep there is nothing left to glob.
    it 'prevents the next incremental regenerate_type_index from resurrecting the orphan' do
      seed_unit_file(models_dir, filename_for('Ghost'), 'Ghost')

      extractor.extract_all
      extractor.send(:regenerate_type_index, :models) # the incremental path's disk-glob rebuild

      index = JSON.parse(File.read(File.join(published_models_dir, '_index.json')))
      expect(index.map { |e| e['identifier'] }).to eq(['User'])

      counts, = extractor.send(:persisted_counts)
      expect(counts[:models]).to eq(1)
    end

    # The incremental path holds only changed units in memory, so "not in
    # memory" means nothing there — its deletions are driven by the graph and
    # the change set (prune_vanished_units, remove_replaced_units), and it
    # must not inherit the sweep.
    it 'does not sweep on the incremental path' do
      seed_unit_file(models_dir, filename_for('Ghost'), 'Ghost')

      expect(extractor).not_to receive(:sweep_orphaned_unit_files)
      extractor.extract_changed([])

      expect(File.exist?(File.join(published_models_dir, filename_for('Ghost')))).to be(true)
    end
  end

  # ── write_incremental_graph_analysis fails closed ───────────────────
  #
  # A broken graph analysis used to warn and continue: finalize_incremental_run
  # would go on to write the manifest and publish a fresh generation over an
  # index whose graph_analysis.json never updated. Re-raising means the whole
  # incremental run aborts before publish_generation, matching every other
  # incremental failure mode (extraction raising, a bad reload).
  describe '#write_incremental_graph_analysis' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      allow(extractor).to receive(:safe_eager_load!)
    end

    after { Woods.configuration = @original_config }

    it 're-raises instead of warning and continuing when analysis fails' do
      broken_analyzer = Class.new do
        def initialize(*); end

        def analyze
          raise StandardError, 'graph corrupted'
        end
      end
      stub_const('Woods::GraphAnalyzer', broken_analyzer)
      allow(extractor).to receive(:write_graph_analysis)

      expect { extractor.send(:write_incremental_graph_analysis) }
        .to raise_error(StandardError, 'graph corrupted')
    end

    it 'extract_changed raises and does not bump the generation when the analysis write fails' do
      allow(extractor).to receive(:reconcile_changed_paths).and_return(Set.new(['User']))
      allow(extractor).to receive(:reconcile_class_based_types).and_return(Set.new)
      allow(extractor).to receive(:rerun_whole_app_extractors).and_return(Set.new)
      allow(extractor).to receive(:prune_vanished_units).and_return(Set.new)
      allow(extractor).to receive(:finalize_incremental_unit_json)
      allow(extractor).to receive(:regenerate_type_index)
      allow(extractor).to receive(:write_dependency_graph)
      allow(extractor).to receive(:write_incremental_graph_analysis).and_raise(StandardError, 'graph corrupted')

      output_dir = extractor.instance_variable_get(:@output_dir)
      before_generation = Woods::Generation.new(output_dir: output_dir).current.number

      expect { extractor.extract_changed(['app/models/user.rb']) }
        .to raise_error(StandardError, 'graph corrupted')

      after_generation = Woods::Generation.new(output_dir: output_dir).current.number
      expect(after_generation).to eq(before_generation)
    end
  end

  # ── estimated_tokens_from ────────────────────────────────────────────

  # A full extraction indexes a unit's token estimate from the in-memory
  # object; an incremental run recomputes it by reading the written file
  # back. The two must agree, or the same unit's `_index.json` entry changes
  # depending on which path last touched it.
  describe '#estimated_tokens_from' do
    def round_trip_estimate(unit)
      extractor.send(:estimated_tokens_from, JSON.parse(JSON.generate(unit.to_h)))
    end

    it 'matches ExtractedUnit#estimated_tokens for plain metadata' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.source_code = "class User < ApplicationRecord\nend\n"
      unit.metadata = { table_name: 'users', column_count: 3 }

      expect(round_trip_estimate(unit)).to eq(unit.estimated_tokens)
    end

    # ActiveSupport's Hash#to_json HTML-escapes `>` to `>`, six
    # characters where JSON.generate — which writes the file — emits one.
    # Any model with a lambda scope in its metadata tripped this.
    it 'matches for metadata containing characters ActiveSupport HTML-escapes' do
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Post', file_path: 'app/models/post.rb')
      unit.source_code = "class Post < ApplicationRecord\nend\n"
      unit.metadata = {
        scopes: [{ name: 'recent', source: '  scope :recent, -> { order(created_at: :desc) }' }],
        note: 'a < b && b > c'
      }

      expect(round_trip_estimate(unit)).to eq(unit.estimated_tokens)
    end

    # A booted Rails app turns HTML-entity escaping on (the ActiveSupport
    # railtie sets it); the bare unit suite doesn't load that railtie, so the
    # condition is established here rather than assumed.
    it 'measures the serialization that is written, not ActiveSupport\'s' do
      require 'active_support/json'
      previous = ActiveSupport::JSON::Encoding.escape_html_entities_in_json
      ActiveSupport::JSON::Encoding.escape_html_entities_in_json = true

      metadata = { source: '-> { x }' }
      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'Scoped', file_path: 'app/models/scoped.rb')
      unit.metadata = metadata

      # Guard the premise: if the two serializers ever stop disagreeing, this
      # example is no longer testing anything.
      expect(metadata.to_json.length).to be > JSON.generate(metadata).length
      expect(unit.estimated_tokens).to eq(Woods::TokenUtils.estimate_tokens(JSON.generate(metadata)))
      expect(round_trip_estimate(unit)).to eq(unit.estimated_tokens)
    ensure
      ActiveSupport::JSON::Encoding.escape_html_entities_in_json = previous
    end
  end

  # ── prune_vanished_units ─────────────────────────────────────────────

  describe '#prune_vanished_units' do
    def register(type:, identifier:, relative_path:)
      unit = Woods::ExtractedUnit.new(
        type: type, identifier: identifier, file_path: File.join(tmpdir, relative_path)
      )
      extractor.dependency_graph.register(unit)
      unit
    end

    def prune(changed_paths)
      change_set = Woods::ChangeSet.new(paths: changed_paths, root: rails_root)
      extractor.send(:prune_vanished_units, change_set, Set.new)
    end

    # On Rails < 7.1, ActiveRecord::SchemaMigration and
    # ActiveRecord::InternalMetadata are real ActiveRecord::Base descendants,
    # so a full extraction emits them with the *convention* path
    # app/models/active_record/schema_migration.rb — a file no application
    # has. That path is claimed by the PORO file rule, so the sweep's
    # file-rule bound doesn't exclude it; pruning it would delete a unit
    # every full extraction still produces.
    it 'leaves a class-based unit whose convention path never existed alone' do
      register(type: :model, identifier: 'ActiveRecord::SchemaMigration',
               relative_path: 'app/models/active_record/schema_migration.rb')

      expect(prune(['app/services/unrelated.rb'])).to be_empty
      expect(extractor.dependency_graph.node_exists?('ActiveRecord::SchemaMigration')).to be(true)
    end

    it 'still removes a class-based unit when the caller names its path' do
      register(type: :model, identifier: 'Ghost', relative_path: 'app/models/ghost.rb')

      expect(prune(['app/models/ghost.rb'])).to contain_exactly('Ghost')
      expect(extractor.dependency_graph.node_exists?('Ghost')).to be(false)
    end

    it 'sweeps a file-based unit the caller forgot to mention' do
      register(type: :service, identifier: 'GoneService', relative_path: 'app/services/gone_service.rb')

      expect(prune(['app/services/other.rb'])).to contain_exactly('GoneService')
    end

    it 'leaves units whose nominal path no file rule claims alone' do
      # BehavioralProfile names config/application.rb, which the dummy tmpdir
      # has no file for and no dispatch rule claims.
      register(type: :configuration, identifier: 'BehavioralProfile', relative_path: 'config/application.rb')

      expect(prune(['app/services/unrelated.rb'])).to be_empty
    end

    it 'leaves paths outside Rails.root alone' do
      unit = Woods::ExtractedUnit.new(
        type: :rails_source, identifier: 'rails/activerecord/lib/active_record/base.rb',
        file_path: '/gems/activerecord/lib/active_record/base.rb'
      )
      extractor.dependency_graph.register(unit)

      expect(prune([])).to be_empty
    end

    # Both units are named `reports` and live in different files. Deleting the
    # view's file must not take the factory with it, and the factory's JSON
    # lives at a different path so the delete has to be per type.
    it 'removes only the type whose file vanished when an identifier names two units' do
      register(type: :service, identifier: 'reports', relative_path: 'app/services/reports.rb')
      surviving = File.join(tmpdir, 'app/models/reports.rb')
      FileUtils.mkdir_p(File.dirname(surviving))
      FileUtils.touch(surviving)
      register(type: :model, identifier: 'reports', relative_path: 'app/models/reports.rb')

      expect(prune(['app/services/reports.rb'])).to contain_exactly('reports')

      expect(extractor.dependency_graph.node_types('reports')).to eq([:model])
      expect(extractor.dependency_graph.units_of_type(:service)).not_to include('reports')
      expect(extractor.dependency_graph.identifiers_for_path(surviving)).to include('reports')
    end

    it 'deletes only the vanished type\'s unit JSON' do
      %w[services models].each { |d| FileUtils.mkdir_p(File.join(tmpdir, 'output', d)) }
      service_json = File.join(tmpdir, 'output', 'services',
                               extractor.send(:collision_safe_filename, 'reports'))
      model_json = File.join(tmpdir, 'output', 'models',
                             extractor.send(:collision_safe_filename, 'reports'))
      [service_json, model_json].each { |f| File.write(f, '{}') }

      register(type: :service, identifier: 'reports', relative_path: 'app/services/reports.rb')
      surviving = File.join(tmpdir, 'app/models/reports.rb')
      FileUtils.mkdir_p(File.dirname(surviving))
      FileUtils.touch(surviving)
      register(type: :model, identifier: 'reports', relative_path: 'app/models/reports.rb')

      prune(['app/services/reports.rb'])

      expect(File.exist?(service_json)).to be(false)
      expect(File.exist?(model_json)).to be(true)
    end
  end

  # ── reconcile_class_based_types — removals ───────────────────────────

  # The hole this closes: {#prune_vanished_units} keys on the source file being
  # gone, so a class deleted from a file that still exists is invisible to it —
  # and class-based units register a *convention* path from the constant name,
  # so a second model in one `.rb` was never attributed to that file anyway.
  # Two models in one file, one deleted, and nothing in the run removes it: it
  # outlives every subsequent incremental. A permanent divergence from a full
  # extraction, not a transient one.
  #
  # Driven here rather than in the booted harness because the harness cannot
  # see it: Zeitwerk unloads only the constant a file is *expected* to define,
  # so a second class defined as a side effect survives the reload, stays in
  # `descendants`, and the in-process full extraction the oracle compares
  # against emits it too. Both sides agree, wrongly.
  describe '#reconcile_class_based_types removals' do
    let(:live_class) { double('Model', name: 'Post') }
    let(:fake_models) { double('ModelExtractor') }

    def register(type:, identifier:)
      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: type, identifier: identifier,
                                 file_path: File.join(tmpdir, "app/models/#{identifier.downcase}.rb"))
      )
    end

    before do
      stub_const('Woods::Extractor::CLASS_BASED_DISCOVERY',
                 { models: { type: :model, method: :extract_model } })
      # extractor_for memoizes into this hash, so seeding it injects the double
      # without stubbing the lookup itself.
      extractor.instance_variable_set(:@incremental_extractors, { models: fake_models })
      allow(fake_models).to receive(:discoverable_classes).and_return([live_class])
      register(type: :model, identifier: 'Post')
      register(type: :model, identifier: 'Sidecar')
    end

    def reconcile
      extractor.send(:reconcile_class_based_types, Set.new)
    end

    context 'when the eager load was complete' do
      before { extractor.instance_variable_set(:@eager_load_complete, true) }

      it 'removes a unit whose class the discovery set no longer holds' do
        expect(reconcile).to contain_exactly('Sidecar')
        expect(extractor.dependency_graph.node_exists?('Sidecar')).to be(false)
        expect(extractor.dependency_graph.node_exists?('Post')).to be(true)
      end

      it 'is idempotent — a second pass finds nothing left to do' do
        reconcile

        expect(reconcile).to be_empty
      end

      # A factory named `Sidecar` is a second node under the same identifier,
      # not a replacement for the model node. Removing the stale model must
      # take that node and only that node.
      it 'removes the stale model without taking a same-named unit of another type' do
        register(type: :factory, identifier: 'Sidecar')

        expect(reconcile).to contain_exactly('Sidecar')
        expect(extractor.dependency_graph.node_types('Sidecar')).to eq([:factory])
        expect(extractor.dependency_graph.units_of_type(:model)).not_to include('Sidecar')
      end
    end

    # The documented NameError fallback loads only EXTRACTION_DIRECTORIES, so
    # descendants are known-partial and the difference would be most of the
    # app. A stale unit is a far better failure than deleting a type wholesale.
    context 'when the eager load fell back to per-directory loading' do
      before { extractor.instance_variable_set(:@eager_load_complete, false) }

      it 'removes nothing' do
        expect(reconcile).to be_empty
        expect(extractor.dependency_graph.node_exists?('Sidecar')).to be(true)
      end
    end

    it 'removes nothing before an eager load has been attempted at all' do
      expect(reconcile).to be_empty
      expect(extractor.dependency_graph.node_exists?('Sidecar')).to be(true)
    end
  end

  # ── deduplicate_results ──────────────────────────────────────────────

  describe '#deduplicate_results' do
    def make_unit(type:, identifier:)
      Woods::ExtractedUnit.new(
        type: type,
        identifier: identifier,
        file_path: "/app/#{type}s/#{identifier}.rb"
      )
    end

    it 'removes duplicate identifiers, keeping first occurrence' do
      first = make_unit(type: :route, identifier: 'GET /posts')
      second = make_unit(type: :route, identifier: 'GET /posts')
      second.metadata = { engine: true }

      extractor.instance_variable_set(:@results, { routes: [first, second] })
      extractor.send(:deduplicate_results)

      expect(extractor.instance_variable_get(:@results)[:routes]).to eq([first])
    end

    it 'leaves types with no duplicates unchanged' do
      unit_a = make_unit(type: :model, identifier: 'User')
      unit_b = make_unit(type: :model, identifier: 'Post')

      extractor.instance_variable_set(:@results, { models: [unit_a, unit_b] })
      extractor.send(:deduplicate_results)

      expect(extractor.instance_variable_get(:@results)[:models]).to eq([unit_a, unit_b])
    end

    it 'deduplicates across types independently' do
      route1 = make_unit(type: :route, identifier: 'GET /posts')
      route2 = make_unit(type: :route, identifier: 'GET /posts')
      job1 = make_unit(type: :job, identifier: 'SyncJob')
      job2 = make_unit(type: :job, identifier: 'SyncJob')

      extractor.instance_variable_set(:@results, { routes: [route1, route2], jobs: [job1, job2] })
      extractor.send(:deduplicate_results)

      results = extractor.instance_variable_get(:@results)
      expect(results[:routes]).to eq([route1])
      expect(results[:jobs]).to eq([job1])
    end

    it 'logs dropped count per type' do
      route1 = make_unit(type: :route, identifier: 'GET /posts')
      route2 = make_unit(type: :route, identifier: 'GET /posts')
      route3 = make_unit(type: :route, identifier: 'GET /posts')

      extractor.instance_variable_set(:@results, { routes: [route1, route2, route3] })

      expect(Rails.logger).to receive(:warn).with(/Deduplicated routes: dropped 2 duplicate/)
      extractor.send(:deduplicate_results)
    end

    it 'deduplicates units that share a source file or have no source file' do
      # Engine/runtime units legitimately re-derive the same identifier from
      # the same (or no) source file — first occurrence wins, as before.
      engine_a = make_unit(type: :route, identifier: 'GET /posts')
      engine_b = make_unit(type: :route, identifier: 'GET /posts')
      engine_a.file_path = nil
      engine_b.file_path = nil

      extractor.instance_variable_set(:@results, { routes: [engine_a, engine_b] })
      extractor.send(:deduplicate_results)

      expect(extractor.instance_variable_get(:@results)[:routes].size).to eq(1)
    end

    it 'aborts when one file path is a real file and the other is absent' do
      runtime = make_unit(type: :job, identifier: 'SyncJob')
      runtime.file_path = nil
      file_derived = make_unit(type: :job, identifier: 'SyncJob')

      extractor.instance_variable_set(:@results, { jobs: [runtime, file_derived] })

      expect { extractor.send(:deduplicate_results) }
        .to raise_error(Woods::ExtractionError, /job 'SyncJob'/)
    end

    it 'aborts when the same type+identifier is derived from different files' do
      # G-1 companion: a same-type identifier collision is unrepresentable in
      # the index (same graph node, last-writer-wins file), and `variants:` is
      # cross-type graph identity only — not an escape hatch. Silence was the
      # bug: both files' units must surface, and extraction must stop.
      parser = make_unit(type: :service, identifier: 'Domain::Container')
      renderer = make_unit(type: :service, identifier: 'Domain::Container')
      renderer.file_path = '/app/services/domain/container/renderer.rb'

      extractor.instance_variable_set(:@results, { services: [parser, renderer] })

      expect { extractor.send(:deduplicate_results) }
        .to raise_error(
          Woods::ExtractionError,
          %r{service 'Domain::Container'.*services/Domain::Container\.rb.*container/renderer\.rb}m
        )
    end
  end

  # ── collision_safe_filename ──────────────────────────────────────────

  describe '#collision_safe_filename' do
    it 'produces a hash-suffixed filename' do
      result = extractor.send(:collision_safe_filename, 'GET /foo/bar')
      expect(result).to match(/\A.+_[a-f0-9]{8}\.json\z/)
    end

    it 'produces different filenames for colliding identifiers' do
      # These two identifiers produce the same safe_filename:
      # "GET /foo/bar" -> "GET__foo_bar.json"
      # "GET /foo_bar" -> "GET__foo_bar.json"
      result_a = extractor.send(:collision_safe_filename, 'GET /foo/bar')
      result_b = extractor.send(:collision_safe_filename, 'GET /foo_bar')

      expect(result_a).not_to eq(result_b)
    end

    it 'is deterministic' do
      result_a = extractor.send(:collision_safe_filename, 'GET /posts')
      result_b = extractor.send(:collision_safe_filename, 'GET /posts')

      expect(result_a).to eq(result_b)
    end
  end

  # ── normalize_file_path ──────────────────────────────────────────────

  describe '#normalize_file_path' do
    it 'strips Rails.root prefix from an absolute path' do
      absolute = File.join(tmpdir, 'app/models/user.rb')
      expect(extractor.send(:normalize_file_path, absolute)).to eq('app/models/user.rb')
    end

    it 'leaves an already-relative path unchanged' do
      expect(extractor.send(:normalize_file_path, 'app/models/user.rb')).to eq('app/models/user.rb')
    end

    it 'returns nil when given nil' do
      expect(extractor.send(:normalize_file_path, nil)).to be_nil
    end

    it 'leaves a gem path unchanged when it does not start with Rails.root' do
      gem_path = '/usr/local/bundle/gems/activerecord-7.1.0/lib/active_record/base.rb'
      expect(extractor.send(:normalize_file_path, gem_path)).to eq(gem_path)
    end

    it 'handles Rails.root without trailing slash' do
      # rails_root is a Pathname; Rails.root.to_s has no trailing slash
      absolute = "#{tmpdir}/app/services/user_service.rb"
      expect(extractor.send(:normalize_file_path, absolute)).to eq('app/services/user_service.rb')
    end
  end

  # ── normalize_file_paths ─────────────────────────────────────────────

  describe '#normalize_file_paths' do
    def make_unit(file_path)
      Woods::ExtractedUnit.new(
        type: :model,
        identifier: 'User',
        file_path: file_path
      )
    end

    it 'normalizes absolute paths across all units in all types' do
      unit_a = make_unit(File.join(tmpdir, 'app/models/user.rb'))
      unit_b = make_unit(File.join(tmpdir, 'app/controllers/users_controller.rb'))

      extractor.instance_variable_set(:@results, { models: [unit_a], controllers: [unit_b] })
      extractor.send(:normalize_file_paths)

      expect(unit_a.file_path).to eq('app/models/user.rb')
      expect(unit_b.file_path).to eq('app/controllers/users_controller.rb')
    end

    it 'leaves already-relative paths unchanged' do
      unit = make_unit('app/models/post.rb')

      extractor.instance_variable_set(:@results, { models: [unit] })
      extractor.send(:normalize_file_paths)

      expect(unit.file_path).to eq('app/models/post.rb')
    end

    it 'leaves nil paths unchanged' do
      unit = make_unit(nil)

      extractor.instance_variable_set(:@results, { models: [unit] })
      extractor.send(:normalize_file_paths)

      expect(unit.file_path).to be_nil
    end

    it 'leaves gem paths unchanged' do
      gem_path = '/usr/local/bundle/gems/activerecord-7.1.0/lib/active_record/base.rb'
      unit = make_unit(gem_path)

      extractor.instance_variable_set(:@results, { rails_source: [unit] })
      extractor.send(:normalize_file_paths)

      expect(unit.file_path).to eq(gem_path)
    end
  end

  # ── EXTRACTION_DIRECTORIES constant ──────────────────────────────────

  describe 'EXTRACTION_DIRECTORIES' do
    it 'is a frozen array' do
      expect(Woods::Extractor::EXTRACTION_DIRECTORIES).to be_frozen
    end

    it 'includes core extraction targets' do
      dirs = Woods::Extractor::EXTRACTION_DIRECTORIES
      expect(dirs).to include('models', 'controllers', 'services', 'jobs', 'mailers')
    end

    it 'does not include graphql (handled separately)' do
      expect(Woods::Extractor::EXTRACTION_DIRECTORIES).not_to include('graphql')
    end
  end

  # ── write_graph_analysis ────────────────────────────────────────────

  describe '#write_graph_analysis' do
    let(:output_dir) { File.join(tmpdir, 'output') }
    let(:extractor)  { described_class.new(output_dir: output_dir) }

    before do
      require 'woods'
      Woods.configuration ||= Woods::Configuration.new
      FileUtils.mkdir_p(output_dir)

      # write_graph_analysis reads dependency_graph.json to compute graph_sha
      File.write(File.join(output_dir, 'dependency_graph.json'), '{"nodes":{},"edges":[]}')

      require 'active_support'
      require 'active_support/core_ext/time'
    end

    after do
      Woods.configuration = Woods::Configuration.new
    end

    it 'includes generated_at timestamp' do
      extractor.instance_variable_set(:@graph_analysis, { hubs: [], orphans: [] })
      extractor.send(:write_graph_analysis)

      output = JSON.parse(File.read(File.join(output_dir, 'graph_analysis.json')))
      expect(output).to have_key('generated_at')
      expect(output['generated_at']).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it 'includes graph_sha matching dependency_graph.json content' do
      extractor.instance_variable_set(:@graph_analysis, { hubs: [], orphans: [] })
      extractor.send(:write_graph_analysis)

      output = JSON.parse(File.read(File.join(output_dir, 'graph_analysis.json')))
      expected_sha = Digest::SHA256.hexdigest('{"nodes":{},"edges":[]}')
      expect(output['graph_sha']).to eq(expected_sha)
    end

    it 'preserves original analysis data alongside staleness metadata' do
      extractor.instance_variable_set(:@graph_analysis, { hubs: %w[User Post], orphans: ['Legacy'] })
      extractor.send(:write_graph_analysis)

      output = JSON.parse(File.read(File.join(output_dir, 'graph_analysis.json')))
      expect(output['hubs']).to eq(%w[User Post])
      expect(output['orphans']).to eq(['Legacy'])
    end

    it 'does not write when @graph_analysis is nil' do
      extractor.instance_variable_set(:@graph_analysis, nil)
      extractor.send(:write_graph_analysis)

      expect(File.exist?(File.join(output_dir, 'graph_analysis.json'))).to be false
    end
  end

  # ── write_structural_summary ──────────────────────────────────────────

  describe '#write_structural_summary' do
    let(:output_dir) { File.join(tmpdir, 'output') }
    let(:extractor)  { described_class.new(output_dir: output_dir) }

    before do
      FileUtils.mkdir_p(output_dir)

      require 'active_support'
      require 'active_support/core_ext/numeric/time'

      # Stub Rails.version for the header line
      allow(Rails).to receive(:version).and_return('8.1.0')
    end

    def make_unit(type:, identifier:, namespace: nil, chunks: [])
      unit = Woods::ExtractedUnit.new(
        type: type,
        identifier: identifier,
        file_path: "/app/#{type}s/#{identifier.downcase.tr('::', '/')}.rb"
      )
      unit.namespace = namespace
      unit.chunks    = chunks
      unit
    end

    def build_results
      {
        models: [
          make_unit(type: :model, identifier: 'User'),
          make_unit(type: :model, identifier: 'Post'),
          *Array.new(10) { |i| make_unit(type: :model, identifier: "Admin::Model#{i}", namespace: 'Admin::') },
          *Array.new(5)  { |i| make_unit(type: :model, identifier: "Api::Model#{i}",   namespace: 'Api::') }
        ],
        controllers: [
          make_unit(type: :controller, identifier: 'ApplicationController'),
          *Array.new(8) { |i| make_unit(type: :controller, identifier: "Api::V1::Controller#{i}", namespace: 'Api::V1::') }
        ],
        jobs: [
          make_unit(type: :job, identifier: 'SyncJob', chunks: [{ text: 'chunk' }]),
          make_unit(type: :job, identifier: 'CleanupJob')
        ]
      }
    end

    let(:results) { build_results }

    before do
      extractor.instance_variable_set(:@results, results)
    end

    it 'writes SUMMARY.md to the output directory' do
      extractor.send(:write_structural_summary)
      expect(File.exist?(File.join(output_dir, 'SUMMARY.md'))).to be true
    end

    it 'produces a file under 32KB' do
      extractor.send(:write_structural_summary)
      size = File.size(File.join(output_dir, 'SUMMARY.md'))
      expect(size).to be < 32_768
    end

    it 'includes category headers with unit counts' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      model_count = results[:models].size
      expect(content).to include("## Models (#{model_count})")

      controller_count = results[:controllers].size
      expect(content).to include("## Controllers (#{controller_count})")

      job_count = results[:jobs].size
      expect(content).to include("## Jobs (#{job_count})")
    end

    it 'includes the header with total units, chunks, and category counts' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      total_units = results.values.sum(&:size)
      expect(content).to include("Units: #{total_units}")
      expect(content).to include('Chunks:')
      expect(content).to include('Categories:')
    end

    it 'includes namespace breakdowns for categories' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      # Models have (root), Admin::, Api:: namespaces
      expect(content).to include('Namespaces:')
      expect(content).to include('Admin::')
      expect(content).to include('Api::')
    end

    it 'does not include individual unit identifiers' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      # No per-unit bullet points — identifiers should not appear as list items
      expect(content).not_to match(/^- User$/)
      expect(content).not_to match(/^- Post$/)
      expect(content).not_to match(/^- SyncJob$/)
      expect(content).not_to match(/^- ApplicationController$/)
    end

    it 'does not use sub-headers for namespaces' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      # Old format used ### namespace sub-headers — new format must not
      expect(content).not_to match(/^### /)
    end

    it 'skips empty categories' do
      results_with_empty = results.merge(services: [])
      extractor.instance_variable_set(:@results, results_with_empty)

      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      expect(content).not_to include('## Services')
    end

    it 'returns early without writing when @results is empty' do
      extractor.instance_variable_set(:@results, {})
      extractor.send(:write_structural_summary)

      expect(File.exist?(File.join(output_dir, 'SUMMARY.md'))).to be false
    end

    it 'includes dependency overview section' do
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      expect(content).to include('## Dependency Overview')
    end

    it 'does not include hub node line when @graph_analysis is nil' do
      extractor.instance_variable_set(:@graph_analysis, nil)
      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      expect(content).not_to include('Hub nodes')
    end

    it 'includes hub node line when significant hubs exist' do
      hub_data = {
        hubs: [
          { identifier: 'Account', dependent_count: 50 },
          { identifier: 'User',    dependent_count: 30 },
          { identifier: 'Minor',   dependent_count: 5  }
        ]
      }
      extractor.instance_variable_set(:@graph_analysis, hub_data)

      extractor.send(:write_structural_summary)
      content = File.read(File.join(output_dir, 'SUMMARY.md'))

      expect(content).to include('Hub nodes (>20 dependents): Account, User')
      expect(content).not_to include('Minor')
    end
  end

  # ── log_summary — warnings ────────────────────────────────────────

  describe '#log_summary' do
    let(:logger) { double('Logger').as_null_object }
    let(:output_dir) { File.join(tmpdir, 'output') }

    before do
      allow(Rails).to receive(:logger).and_return(logger)
      extractor.instance_variable_set(:@results, {})
    end

    it 'logs warnings from extractors that respond to :warnings' do
      mock_extractor = double('MockExtractor')
      allow(mock_extractor).to receive(:respond_to?).with(:warnings).and_return(true)
      warning_msg = '[Post] Skipping broken association tags: ' \
                    'uninitialized constant Tags'
      allow(mock_extractor).to receive(:warnings).and_return([warning_msg])

      extractor.instance_variable_set(:@extractors, { model: mock_extractor })

      expect(logger).to receive(:warn).with(a_string_including('Warnings (1)'))
      expect(logger).to receive(:warn).with(a_string_including('Skipping broken association tags'))

      extractor.send(:log_summary)
    end

    it 'does not log a warnings section when no extractors have warnings' do
      mock_extractor = double('MockExtractor')
      allow(mock_extractor).to receive(:respond_to?).with(:warnings).and_return(true)
      allow(mock_extractor).to receive(:warnings).and_return([])

      extractor.instance_variable_set(:@extractors, { model: mock_extractor })

      expect(logger).not_to receive(:warn)

      extractor.send(:log_summary)
    end

    it 'skips extractors that do not respond to :warnings' do
      mock_extractor = double('MockExtractor')
      allow(mock_extractor).to receive(:respond_to?).with(:warnings).and_return(false)

      extractor.instance_variable_set(:@extractors, { route: mock_extractor })

      expect(logger).not_to receive(:warn)

      extractor.send(:log_summary)
    end
  end

  # A routes change replaces every route-consuming type wholesale, and almost
  # all of those units re-serialize to the bytes already on disk. Skipping the
  # write must not skip the bookkeeping equivalence depends on.
  describe '#write_unit_file' do
    let(:write_tmpdir) { Dir.mktmpdir('woods_write_skip') }
    let(:output_dir) { File.join(write_tmpdir, 'output') }
    let(:extractor) { described_class.new(output_dir: output_dir) }

    # `json_serialize` reads `Woods.configuration.pretty_json`, so these
    # examples must establish a configuration rather than inherit whatever an
    # earlier example left behind — under a random seed they can run first.
    #
    # Time is frozen because `ExtractedUnit#to_h` stamps `extracted_at` from
    # `Time.now`: before the #208 mask, the same-bytes examples only passed
    # when both serializations landed in the same wall-clock second — a flake
    # by construction. The #208 examples below advance the clock explicitly.
    let(:base_time) { Time.at(1_700_000_000) }

    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      FileUtils.mkdir_p(output_dir)
      allow(Time).to receive(:now).and_return(base_time)
    end

    after do
      Woods.configuration = @original_config
      FileUtils.rm_rf(write_tmpdir)
    end
    let(:unit) do
      Woods::ExtractedUnit.new(
        type: :model, identifier: 'Widget', file_path: 'app/models/widget.rb'
      ).tap { |u| u.source_code = 'class Widget; end' }
    end
    let(:target) { Pathname.new(File.join(output_dir, 'widget.json')) }

    it 'writes when the file does not exist' do
      extractor.send(:write_unit_file, target, unit)

      expect(target).to exist
    end

    it 'does not rewrite when the bytes are unchanged' do
      extractor.send(:write_unit_file, target, unit)
      expect(Woods::AtomicFile).not_to receive(:write)

      extractor.send(:write_unit_file, target, unit)
    end

    it 'rewrites when the content changed' do
      extractor.send(:write_unit_file, target, unit)
      unit.source_code = 'class Widget; def call; end; end'

      extractor.send(:write_unit_file, target, unit)

      expect(Woods::AtomicFile.read(target)).to include('def call')
    end

    it 'rewrites when the file on disk is corrupt' do
      File.binwrite(target, 'not json at all')

      extractor.send(:write_unit_file, target, unit)

      expect(Woods::AtomicFile.read(target)).to include('Widget')
    end

    # #208 — ExtractedUnit#to_h stamps `extracted_at: Time.now.iso8601` on
    # every serialization, so compared raw the bytes never matched across
    # runs: the documented fsync-avoidance read every file and wrote it
    # anyway. The comparison must be insensitive to the stamp and nothing
    # else.
    it 'skips the rewrite when only the extracted_at stamp differs (#208)' do
      extractor.send(:write_unit_file, target, unit)

      allow(Time).to receive(:now).and_return(base_time + 3600)
      expect(Woods::AtomicFile).not_to receive(:write)

      extractor.send(:write_unit_file, target, unit)

      # The *older* stamp stays on disk — deliberately. The equivalence
      # oracle (spec/support/index_comparison.rb) lists extracted_at in
      # VOLATILE_UNIT_KEYS: an untouched unit keeping an older stamp is
      # inside the contract.
      expect(JSON.parse(Woods::AtomicFile.read(target))['extracted_at']).to eq(base_time.iso8601)
    end

    it 'still rewrites when a real field changed along with the stamp' do
      extractor.send(:write_unit_file, target, unit)

      allow(Time).to receive(:now).and_return(base_time + 3600)
      unit.source_code = 'class Widget; def call; end; end'

      extractor.send(:write_unit_file, target, unit)

      written = JSON.parse(Woods::AtomicFile.read(target))
      expect(written['source_code']).to include('def call')
      expect(written['extracted_at']).to eq((base_time + 3600).iso8601)
    end

    # json_serialize has two output shapes; the mask must match the stamp in
    # both ("extracted_at":"..." compact, "extracted_at": "..." pretty).
    it 'skips the rewrite under pretty_json output too' do
      Woods.configuration.pretty_json = true
      extractor.send(:write_unit_file, target, unit)

      allow(Time).to receive(:now).and_return(base_time + 3600)
      expect(Woods::AtomicFile).not_to receive(:write)

      extractor.send(:write_unit_file, target, unit)
    end
  end

  # #167 — GraphQL is the one class-based entry whose discovery set is not
  # authoritative for its unit type, because the type is produced by the union
  # of runtime introspection and a static file pass. Reading absence from the
  # runtime set as deletion would wipe every GraphQL unit in the index whenever
  # graphql-ruby is not loaded, and would delete file-defined types not attached
  # to the schema even when it is.
  #
  # This is a guard on the wiring, not a behavioural test of a live reconcile —
  # the behaviour needs graphql-ruby installed to observe, which is #167's
  # remaining unvalidated surface.
  describe 'CLASS_BASED_DISCOVERY removal opt-out' do
    it 'opts GraphQL out of removal reconciliation' do
      expect(described_class::CLASS_BASED_DISCOVERY[:graphql][:reconcile_removals]).to be false
    end

    it 'leaves every other entry subject to removal' do
      others = described_class::CLASS_BASED_DISCOVERY.except(:graphql)

      expect(others.values.map { |spec| spec[:reconcile_removals] }).to all(be_nil)
    end

    it 'routes GraphQL additions at the runtime-introspection extractor' do
      spec = described_class::CLASS_BASED_DISCOVERY[:graphql]

      expect(spec[:type]).to eq(:graphql_type)
      expect(spec[:method]).to eq(:extract_from_runtime_type)
    end

    # {Extractor#add_discovered_classes} calls
    # `extractor_for(key).public_send(spec[:method], klass)`. A private method
    # there raises NoMethodError, which the surrounding `rescue StandardError`
    # turns into a warn and a nil that `filter_map` drops — so the entry
    # silently contributes nothing rather than failing loudly.
    #
    # Asserting the symbol matches the table (above) does not catch that, and
    # neither do the reconcile specs: they inject a double, which answers
    # `public_send` for anything stubbed on it regardless of the real class's
    # visibility. Visibility is a static property, so unlike a behavioural
    # reconcile test this needs neither graphql-ruby nor a booted app.
    #
    # Regression: #167 shipped with `extract_from_runtime_type` below
    # `private`, making the whole change inert.
    it 'exposes every discovery method as a public instance method' do
      offenders = described_class::CLASS_BASED_DISCOVERY.filter_map do |key, spec|
        extractor_class = described_class::EXTRACTORS[key]
        next if extractor_class.nil?
        next if extractor_class.public_method_defined?(spec[:method])

        "#{key} -> #{extractor_class}##{spec[:method]}"
      end

      expect(offenders).to be_empty,
                           'these discovery methods are not publicly callable, so public_send ' \
                           "raises NoMethodError and the entry adds nothing: #{offenders.join(', ')}"
    end
  end

  # Both of these are #167 regressions found in review: the change added
  # runtime-only GraphQL types to the incremental path, and two separate
  # mechanisms then undid it.
  describe 'GraphQL incremental reconciliation (#167)' do
    # The behavioural half of the `types:` fix is the `known` union in
    # reconcile_class_based_types. Asserting the table holds GRAPHQL_TYPES is a
    # tautology — the table literally holds that constant — and the whole suite
    # passes with the union reverted, because graphql-ruby is in no bundle so
    # `discoverable_classes` returns [] and the addition path never fires.
    #
    # This drives the union directly with a stubbed multi-type entry: the class
    # is already in the graph under the entry's *second* type, so a `known`
    # built from `spec[:type]` alone misses it and re-adds it every run —
    # leaving `touched` non-empty on a no-op, which rewrites the manifest and
    # bumps the generation each cycle.
    it 'treats a unit known under a secondary type as already known' do
      already_known = double('QueryType', name: 'Types::QueryType')
      fake = double('GraphQLExtractor', discoverable_classes: [already_known])
      stub_const('Woods::Extractor::CLASS_BASED_DISCOVERY',
                 { graphql: { type: :graphql_type, types: %i[graphql_type graphql_query],
                              method: :extract_from_runtime_type, reconcile_removals: false } })
      extractor.instance_variable_set(:@incremental_extractors, { graphql: fake })
      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: :graphql_query, identifier: 'Types::QueryType',
                                 file_path: File.join(tmpdir, 'app/graphql/types/query_type.rb'))
      )

      expect(extractor.send(:reconcile_class_based_types, Set.new)).to be_empty
    end

    it 'covers every unit type the extractor emits, not just graphql_type' do
      spec = described_class::CLASS_BASED_DISCOVERY[:graphql]

      # classify_runtime_type returns four types; the schema's query root is
      # always in Schema.types and classifies as :graphql_query. Declaring only
      # :graphql_type left the others permanently "new", so they were re-added
      # every run — leaving `touched` non-empty on a no-op and bumping the
      # generation each cycle.
      expect(spec[:types]).to eq(described_class::GRAPHQL_TYPES)
      expect(spec[:types]).to include(:graphql_query)
    end

    # Per-unit, not per-type (B-070). `source_file_for_class` derives exactly one
    # fallback — app/graphql/<constant.underscore>.rb — so a unit sitting at that
    # path has no file behind it and must be spared. Any other path came from the
    # static file pass and is sweepable like anything else.
    def register_graphql(identifier, file_path)
      graph = Woods::DependencyGraph.new
      graph.register(
        Woods::ExtractedUnit.new(type: :graphql_query, identifier: identifier, file_path: file_path)
      )
      described_class.new(output_dir: Dir.mktmpdir).tap do |extractor|
        extractor.instance_variable_set(:@dependency_graph, graph)
      end
    end

    # B-070 is fixed at the source rather than in this predicate: a
    # runtime-defined type now records file_path = nil, so it never enters
    # `file_map` and the path sweep cannot reach it. GraphQL is therefore back
    # out of `convention_path_unit?` entirely, and a file-defined type — which
    # has a real path — is swept like anything else.
    it 'does not spare a file-defined GraphQL type' do
      extractor = register_graphql(
        'Types::PostType', Rails.root.join('app/graphql/types/nested/post_type.rb').to_s
      )

      expect(extractor.send(:convention_path_unit?, 'Types::PostType')).to be false
    end

    it 'does not need to spare a runtime-defined type, because it has no path to sweep' do
      graph = Woods::DependencyGraph.new
      graph.register(
        Woods::ExtractedUnit.new(type: :graphql_query, identifier: 'Types::QueryType', file_path: nil)
      )

      expect(graph.to_h[:file_map]).to be_empty
    end

    it 'still treats a genuinely file-based unit as sweepable' do
      graph = Woods::DependencyGraph.new
      graph.register(
        Woods::ExtractedUnit.new(type: :lib, identifier: 'Thing', file_path: '/nope/lib/thing.rb')
      )
      extractor = described_class.new(output_dir: Dir.mktmpdir)
      extractor.instance_variable_set(:@dependency_graph, graph)

      expect(extractor.send(:convention_path_unit?, 'Thing')).to be false
    end
  end

  # ── begin_payload! strict degrade (P2) ───────────────────────────────
  #
  # An incremental run's write set is only the units it touched. Degrading a
  # failed payload-directory open to a flat publish is sound for a FULL
  # extraction (its write set is everything), but for extract_changed/refresh
  # over a payload-born index the flat root holds nothing newer than the last
  # time the index was flat — so the degrade would both compute the wrong
  # incremental baseline and publish an index missing every untouched unit.
  describe '#begin_payload! strict degrade (P2)' do
    let(:output_dir) { File.join(tmpdir, 'output') }

    before { FileUtils.mkdir_p(output_dir) }

    # Publishes a generation whose payload lives under payloads/gen-1 rather
    # than the flat output root, mimicking an index that has already moved
    # onto the payload layout.
    def publish_payload_born_generation
      store = Woods::PayloadStore.new(output_dir)
      dir = store.create(1)
      FileUtils.mkdir_p(dir.join('models'))
      File.write(dir.join('dependency_graph.json'),
                 JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))
      File.write(dir.join('manifest.json'), '{}')
      Woods::Generation.new(output_dir: output_dir)
                       .bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
    end

    it 'aborts extract_changed instead of publishing a collapsed flat index' do
      require 'woods'
      publish_payload_born_generation
      store = extractor.instance_variable_get(:@payload_store)
      allow(store).to receive(:create).and_raise(Errno::EACCES, 'denied')

      expect { extractor.extract_changed(['app/models/user.rb']) }
        .to raise_error(Woods::ExtractionError, /payload/i)

      expect(Woods::Generation.new(output_dir: output_dir).current.number).to eq(1)
    end

    it 'aborts refresh instead of publishing a collapsed flat index' do
      require 'woods'
      publish_payload_born_generation
      store = extractor.instance_variable_get(:@payload_store)
      allow(store).to receive(:create).and_raise(Errno::EACCES, 'denied')

      expect { extractor.refresh(:routes) }
        .to raise_error(Woods::ExtractionError, /payload/i)

      expect(Woods::Generation.new(output_dir: output_dir).current.number).to eq(1)
    end

    # Existing behavior, pinned: a full run's write set is complete, so
    # degrading to flat still produces a correct manifest and unit set — it
    # is only the incremental paths above that cannot make this safe.
    it 'still publishes a complete flat index on full extraction when payload creation fails' do
      require 'woods'
      require 'active_support'
      require 'active_support/isolated_execution_state'
      require 'active_support/core_ext/time'
      require 'active_support/core_ext/string/inflections'
      original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.concurrent_extraction = false
      allow(Time).to receive(:current).and_return(Time.now)
      allow(Rails).to receive(:version).and_return('8.0.0')
      allow(extractor).to receive(:safe_eager_load!)
      allow(extractor).to receive(:git_available?).and_return(false)

      unit = Woods::ExtractedUnit.new(type: :model, identifier: 'User', file_path: 'app/models/user.rb')
      unit.source_code = 'class User; end'
      fake_models_class = Class.new { define_method(:extract_all) { [unit] } }
      fake_empty_class = Class.new do
        def extract_all
          []
        end
      end
      stub_const('Woods::Extractor::EXTRACTORS',
                 { models: fake_models_class, rails_source: fake_empty_class })

      store = extractor.instance_variable_get(:@payload_store)
      allow(store).to receive(:create).and_raise(Errno::EACCES, 'denied')

      extractor.extract_all

      filename = extractor.send(:collision_safe_filename, 'User')
      expect(File.exist?(File.join(output_dir, 'models', filename))).to be(true)
      expect(File.exist?(File.join(output_dir, 'models', '_index.json'))).to be(true)

      generation_data = JSON.parse(File.read(File.join(output_dir, 'generation.json')))
      expect(generation_data).not_to have_key('payload')

      manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
      expect(manifest['total_units']).to eq(1)

      Woods.configuration = original_config
    end
  end

  # ── seed_payload_from_flat_root cross-device fallback (P3) ───────────
  #
  # PayloadStore#link_or_copy already rescues EXDEV/EPERM/EMLINK/
  # NotImplementedError and copies instead — but this file-level seeding
  # bypassed it with a bare FileUtils.ln, so a filesystem that disallows
  # hardlinks raised here on EVERY run and begin_payload! degraded to flat
  # every time, never giving the fallback a chance to activate.
  describe '#seed_payload_from_flat_root cross-device fallback (P3)' do
    it 'copies a flat-root file into the payload instead of raising' do
      output_dir = File.join(tmpdir, 'output')
      FileUtils.mkdir_p(output_dir)
      File.write(File.join(output_dir, 'manifest.json'), '{"total_units":1}')

      target_extractor = described_class.new(output_dir: output_dir)
      payload_store = Woods::PayloadStore.new(output_dir)
      payload_dir = payload_store.create(1)
      target_extractor.instance_variable_set(:@payload_dir, payload_dir)
      allow(FileUtils).to receive(:ln).and_raise(Errno::EXDEV, 'cross-device link')

      expect { target_extractor.send(:seed_payload_from_flat_root) }.not_to raise_error
      expect(File.read(payload_dir.join('manifest.json'))).to eq('{"total_units":1}')
    end
  end

  # ── remove_replaced_units typed identity (#225) ──────────────────────

  # Two independent bugs in the same method: (1) the removal loop called
  # `remove_unit` without `type:`, which fans over every type registered
  # under an identifier — so a wholesale replacement of one extractor's
  # output deleted a same-named unit belonging to a completely different
  # extractor; (2) `fresh` was computed once per extractor KEY rather than
  # once per unit TYPE, so a unit reclassified between two types the same
  # key owns (GraphQL's four) never counted as stale under its old type.
  describe '#remove_replaced_units typed identity (#225)' do
    def register(type:, identifier:)
      extractor.dependency_graph.register(
        Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil)
      )
    end

    def write_json(extractor_key, identifier)
      dir = File.join(tmpdir, 'output', extractor_key.to_s)
      FileUtils.mkdir_p(dir)
      File.write(
        File.join(dir, extractor.send(:collision_safe_filename, identifier)),
        JSON.generate(identifier: identifier)
      )
    end

    # Reproduces the live incident: a `database_views` re-run's removal pass
    # must not take a same-named `factories` unit with it. Both types are
    # unconditional (file-derived) whole-app extractors, so neither is gated
    # on `@eager_load_complete`.
    it "removes only the replaced key's own type, sparing a same-identifier unit of another type" do
      register(type: :database_view, identifier: 'reports')
      write_json(:database_views, 'reports')
      register(type: :factory, identifier: 'reports')
      write_json(:factories, 'reports')

      extractor.instance_variable_set(
        :@incremental_extractors,
        { database_views: double('DatabaseViewExtractor', extract_all: []) }
      )

      extractor.send(:replace_type_wholesale, :database_views, Set.new)

      expect(extractor.dependency_graph.node_types('reports')).to eq([:factory])
      expect(extractor.dependency_graph.units_of_type(:factory)).to include('reports')
      database_view_json = File.join(tmpdir, 'output', 'database_views',
                                     extractor.send(:collision_safe_filename, 'reports'))
      factory_json = File.join(tmpdir, 'output', 'factories',
                               extractor.send(:collision_safe_filename, 'reports'))
      expect(File.exist?(database_view_json)).to be(false)
      expect(File.exist?(factory_json)).to be(true)
    end

    # GraphQL owns four types (graphql_type/mutation/resolver/query) under
    # one extractor key. Simulate a unit reclassified from graphql_type to
    # graphql_query across a run: a key-wide `fresh` set would see the
    # identifier as "still fresh" (present under the new type) and leave the
    # stale graphql_type node behind.
    it 'removes the stale old-type node when a unit is reclassified between two types of one key' do
      register(type: :graphql_type, identifier: 'Schema::Widget')
      fresh = Woods::ExtractedUnit.new(type: :graphql_query, identifier: 'Schema::Widget', file_path: nil)
      extractor.instance_variable_set(
        :@incremental_extractors,
        { graphql: double('GraphQLExtractor', extract_all: [fresh]) }
      )
      extractor.instance_variable_set(:@eager_load_complete, true)

      extractor.send(:replace_type_wholesale, :graphql, Set.new)

      expect(extractor.dependency_graph.node_types('Schema::Widget')).to eq([:graphql_query])
    end
  end

  # ── resolve_dependents typed identity (#225) ─────────────────────────

  # unit_map used to be identifier => unit, so a colliding identifier's later
  # registration overwrote the earlier one and every dependent landed on
  # whichever unit happened to be indexed last — the other unit serialized
  # `dependents: []` forever, disagreeing with the incremental path (which
  # already treats dependents as a property of the identifier).
  describe '#resolve_dependents typed identity (#225)' do
    it 'attaches a dependent to every unit sharing a colliding identifier' do
      view = Woods::ExtractedUnit.new(type: :database_view, identifier: 'reports', file_path: nil)
      factory = Woods::ExtractedUnit.new(type: :factory, identifier: 'reports', file_path: nil)
      dependent = Woods::ExtractedUnit.new(type: :model, identifier: 'Report', file_path: nil)
      dependent.dependencies = [{ target: 'reports', via: :code_reference }]

      extractor.instance_variable_set(:@results, {
                                        database_views: [view],
                                        factories: [factory],
                                        models: [dependent]
                                      })

      extractor.send(:resolve_dependents)

      expect(view.dependents).to eq([{ type: :model, identifier: 'Report' }])
      expect(factory.dependents).to eq([{ type: :model, identifier: 'Report' }])
    end
  end

  # ── finalize_incremental_unit_json per-type git metadata (#225) ──────

  # `@incremental_written` is identifier => file_path, last-writer-wins, so a
  # single pre-resolved git hash applied to every colliding type's JSON put
  # one type's commit history into another type's `metadata.git`. Each type
  # must resolve git data against its OWN file_path.
  describe '#finalize_incremental_unit_json per-type git metadata (#225)' do
    before do
      require 'woods'
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
    end

    after { Woods.configuration = @original_config }

    def register(type:, identifier:, relative_path:)
      unit = Woods::ExtractedUnit.new(
        type: type, identifier: identifier, file_path: File.join(tmpdir, relative_path)
      )
      extractor.dependency_graph.register(unit)
      unit
    end

    def write_json(extractor_key, identifier)
      dir = File.join(tmpdir, 'output', extractor_key.to_s)
      FileUtils.mkdir_p(dir)
      File.write(
        File.join(dir, extractor.send(:collision_safe_filename, identifier)),
        JSON.generate(identifier: identifier, metadata: {})
      )
    end

    it "gives each colliding type its own file's git data, not the last-registered type's" do
      register(type: :database_view, identifier: 'reports', relative_path: 'db/views/reports.sql')
      write_json(:database_views, 'reports')
      register(type: :factory, identifier: 'reports', relative_path: 'spec/factories/reports.rb')
      write_json(:factories, 'reports')

      # Both types were written through register_and_write in the same run,
      # so @incremental_written is last-writer-wins per identifier — here,
      # the factory's path, since it registered second.
      extractor.instance_variable_set(:@incremental_written, { 'reports' => 'spec/factories/reports.rb' })
      extractor.instance_variable_set(:@dependents_dirty, Set.new)

      allow(extractor).to receive(:incremental_git_data).and_return(
        'db/views/reports.sql' => { 'last_author' => 'Alice' },
        'spec/factories/reports.rb' => { 'last_author' => 'Bob' }
      )

      extractor.send(:finalize_incremental_unit_json, Set.new)

      view_json = JSON.parse(File.read(File.join(tmpdir, 'output', 'database_views',
                                                 extractor.send(:collision_safe_filename, 'reports'))))
      factory_json = JSON.parse(File.read(File.join(tmpdir, 'output', 'factories',
                                                    extractor.send(:collision_safe_filename, 'reports'))))

      expect(view_json['metadata']['git']).to eq('last_author' => 'Alice')
      expect(factory_json['metadata']['git']).to eq('last_author' => 'Bob')
    end
  end

  # ── AtomicFile.read on Woods' own JSON artifacts (#225) ──────────────

  # A bare File.read tags what comes back with the process's default
  # external encoding — US-ASCII under LANG=C, the documented daemon
  # environment — so any multibyte byte in a unit's source raised
  # Encoding::InvalidByteSequenceError on the first JSON.parse.
  describe '#regenerate_type_index encoding (#225)' do
    around do |example|
      original = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      example.run
    ensure
      Encoding.default_external = original
    end

    it 'reads unit JSON via AtomicFile.read and does not raise under a US-ASCII default external encoding' do
      type_dir = File.join(tmpdir, 'output', 'models')
      FileUtils.mkdir_p(type_dir)
      source_code = 'class Foo; end # em dash —'
      payload = JSON.generate(
        identifier: 'Foo', file_path: 'app/models/foo.rb', namespace: nil,
        source_code: source_code, metadata: {}, chunks: []
      )
      # binwrite, not File.write: writing a UTF-8 string through a text-mode
      # File.write under a US-ASCII default external encoding would raise on
      # the write side, before the read path under test ever runs.
      File.binwrite(File.join(type_dir, extractor.send(:collision_safe_filename, 'Foo')), payload)

      expect { extractor.send(:regenerate_type_index, :models) }.not_to raise_error
    end
  end
end
