# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'active_support'
require 'active_support/core_ext/time'
require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'codebase_index'
require 'codebase_index/extractor'

RSpec.describe CodebaseIndex::Extractor, 'concurrent extraction' do
  let(:tmpdir) { Dir.mktmpdir('codebase_index_test') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:output_dir) { File.join(tmpdir, 'output') }
  let(:extractor) { described_class.new(output_dir: output_dir) }
  let(:fake_time) { Time.new(2026, 1, 1) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
    allow(Rails).to receive(:version).and_return('7.1.0')

    allow(Time).to receive(:current).and_return(fake_time)

    # Stub eager loading and git
    allow(extractor).to receive(:safe_eager_load!)
    allow(extractor).to receive(:git_available?).and_return(false)
  end

  after do
    FileUtils.rm_rf(tmpdir)
    CodebaseIndex.configuration = CodebaseIndex::Configuration.new
    CodebaseIndex::ModelNameCache.reset!
  end

  # ── Configuration defaults ──────────────────────────────────────────

  describe 'concurrent_extraction config flag' do
    it 'defaults to false' do
      config = CodebaseIndex::Configuration.new
      expect(config.concurrent_extraction).to be false
    end

    it 'can be set to true' do
      CodebaseIndex.configure { |c| c.concurrent_extraction = true }
      expect(CodebaseIndex.configuration.concurrent_extraction).to be true
    end
  end

  # ── Sequential vs Concurrent parity ─────────────────────────────────

  describe 'extraction parity' do
    let(:fake_units) do
      user = CodebaseIndex::ExtractedUnit.new(
        identifier: 'User', type: :model, file_path: '/app/models/user.rb'
      )
      user.source_code = 'class User; end'

      auth = CodebaseIndex::ExtractedUnit.new(
        identifier: 'AuthService', type: :service, file_path: '/app/services/auth.rb'
      )
      auth.source_code = 'class AuthService; end'

      { models: [user], services: [auth] }
    end

    before do
      CodebaseIndex::Extractor::EXTRACTORS.each do |type, klass|
        extractor_double = instance_double(klass, extract_all: fake_units.fetch(type, []))
        allow(klass).to receive(:new).and_return(extractor_double)
      end

      allow(CodebaseIndex::ModelNameCache).to receive(:model_names).and_return([])
      allow(CodebaseIndex::ModelNameCache).to receive(:model_names_regex).and_return(/(?!)/)
    end

    it 'produces the same unit identifiers in both modes' do
      # Sequential
      CodebaseIndex.configure { |c| c.concurrent_extraction = false }
      sequential_results = extractor.extract_all
      sequential_ids = sequential_results.values.flatten.map(&:identifier).sort

      # Reset for concurrent run
      concurrent_extractor = described_class.new(output_dir: File.join(tmpdir, 'output_concurrent'))
      allow(concurrent_extractor).to receive(:safe_eager_load!)
      allow(concurrent_extractor).to receive(:git_available?).and_return(false)

      CodebaseIndex.configure { |c| c.concurrent_extraction = true }
      concurrent_results = concurrent_extractor.extract_all
      concurrent_ids = concurrent_results.values.flatten.map(&:identifier).sort

      expect(concurrent_ids).to eq(sequential_ids)
    end

    it 'registers all units in the dependency graph when concurrent' do
      CodebaseIndex.configure { |c| c.concurrent_extraction = true }
      extractor.extract_all

      graph = extractor.dependency_graph
      graph_hash = graph.to_h
      registered_ids = graph_hash[:nodes].keys

      expect(registered_ids).to include('User', 'AuthService')
    end
  end

  # ── ModelNameCache pre-computation ──────────────────────────────────

  describe 'ModelNameCache pre-computation' do
    before do
      CodebaseIndex::Extractor::EXTRACTORS.each_value do |klass|
        allow(klass).to receive(:new).and_return(double(extract_all: []))
      end
    end

    it 'warms ModelNameCache before spawning threads in concurrent mode' do
      CodebaseIndex.configure { |c| c.concurrent_extraction = true }

      cache_warmed_at = nil
      first_thread_at = nil

      allow(CodebaseIndex::ModelNameCache).to receive(:model_names) do
        cache_warmed_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        []
      end
      allow(CodebaseIndex::ModelNameCache).to receive(:model_names_regex).and_return(/(?!)/)

      # Track when the first thread-spawned extractor runs
      CodebaseIndex::Extractor::EXTRACTORS.each_value do |klass|
        extractor_double = double(extract_all: [])
        allow(extractor_double).to receive(:extract_all) do
          first_thread_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          []
        end
        allow(klass).to receive(:new).and_return(extractor_double)
      end

      extractor.extract_all

      expect(cache_warmed_at).not_to be_nil
      expect(first_thread_at).not_to be_nil
      expect(cache_warmed_at).to be <= first_thread_at
    end
  end

  # ── Error isolation ─────────────────────────────────────────────────

  describe 'concurrent error isolation' do
    before do
      allow(CodebaseIndex::ModelNameCache).to receive(:model_names).and_return([])
      allow(CodebaseIndex::ModelNameCache).to receive(:model_names_regex).and_return(/(?!)/)
    end

    it 'isolates extractor failures without crashing other threads' do
      CodebaseIndex.configure { |c| c.concurrent_extraction = true }

      CodebaseIndex::Extractor::EXTRACTORS.each do |type, klass|
        if type == :models
          bad_extractor = double('BadExtractor')
          allow(bad_extractor).to receive(:extract_all).and_raise(StandardError, 'boom')
          allow(klass).to receive(:new).and_return(bad_extractor)
        else
          allow(klass).to receive(:new).and_return(double(extract_all: []))
        end
      end

      results = extractor.extract_all

      # Models should have empty results (error caught), not crash the whole extraction
      expect(results[:models]).to eq([])
      # Other extractors should still succeed
      expect(results[:services]).to eq([])
    end
  end
end
