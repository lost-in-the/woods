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
      require 'active_support/core_ext/numeric/time'

      file_paths = (1..1100).map { |i| File.join(tmpdir, "file_#{i}.rb") }

      allow(extractor).to receive(:parse_git_log_output)
      allow(extractor).to receive(:build_file_metadata).and_return({})

      # Time.current is an ActiveSupport extension; stub it with a plain object
      # that supports the arithmetic used in batch_git_data.
      fake_ninety = double('ninety_days_ago', iso8601: '2023-10-01T00:00:00Z')
      fake_now    = double('now')
      allow(fake_now).to receive(:-).and_return(fake_ninety)
      time_stub = Module.new
      time_stub.define_singleton_method(:current) { fake_now }
      stub_const('Time', time_stub)

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
end
