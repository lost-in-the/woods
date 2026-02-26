# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractor'

RSpec.describe CodebaseIndex::Extractor do
  # Use a real tmpdir so Pathname#exist? works without stubs.
  let(:tmpdir) { Dir.mktmpdir('codebase_index_test') }
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

  # ── json_serialize ───────────────────────────────────────────────────

  describe '#json_serialize' do
    before do
      require 'codebase_index'
      CodebaseIndex.configuration ||= CodebaseIndex::Configuration.new
    end

    after do
      CodebaseIndex.configuration = CodebaseIndex::Configuration.new
    end

    it 'returns pretty JSON when pretty_json is true' do
      CodebaseIndex.configuration.pretty_json = true
      output = extractor.send(:json_serialize, { key: 'value' })
      expect(output).to include("\n")
    end

    it 'returns compact JSON when pretty_json is false' do
      CodebaseIndex.configuration.pretty_json = false
      output = extractor.send(:json_serialize, { key: 'value' })
      expect(output).not_to include("\n")
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
      allow(graph).to receive(:to_h).and_return({ nodes: { '../malicious/path' => node } })

      # constantize must NOT be called for an invalid identifier
      expect_any_instance_of(String).not_to receive(:constantize)

      extractor.send(:re_extract_unit, '../malicious/path')
    end

    it 'allows constantize for valid Ruby constant identifiers' do
      node = { type: 'model', file_path: File.join(tmpdir, 'user.rb') }
      FileUtils.touch(File.join(tmpdir, 'user.rb'))

      graph = extractor.instance_variable_get(:@dependency_graph)
      allow(graph).to receive(:to_h).and_return({ nodes: { 'User' => node } })

      extractor_double = double('ModelExtractor')
      allow(CodebaseIndex::Extractors::ModelExtractor).to receive(:new).and_return(extractor_double)

      # constantize raises NameError (no Rails env) — that's fine, it just returns nil
      # The important thing is no error from the format check itself
      expect { extractor.send(:re_extract_unit, 'User') }.not_to raise_error
    end
  end

  # ── deduplicate_results ──────────────────────────────────────────────

  describe '#deduplicate_results' do
    def make_unit(type:, identifier:)
      CodebaseIndex::ExtractedUnit.new(
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
      CodebaseIndex::ExtractedUnit.new(
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
      expect(CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES).to be_frozen
    end

    it 'includes core extraction targets' do
      dirs = CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES
      expect(dirs).to include('models', 'controllers', 'services', 'jobs', 'mailers')
    end

    it 'does not include graphql (handled separately)' do
      expect(CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES).not_to include('graphql')
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
      unit = CodebaseIndex::ExtractedUnit.new(
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
end
