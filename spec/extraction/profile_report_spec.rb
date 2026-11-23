# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/extraction/profile_report'
require 'woods/extractor'

RSpec.describe Woods::Extraction::ProfileReport do
  let(:tmpdir) { Dir.mktmpdir('woods_profile_report') }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#measure_phase and #finish' do
    it 'records wall time, CPU time, allocations, GC deltas, and ranked summaries' do
      report = described_class.new(operation: 'full')
      report.start

      result, elapsed = report.measure_phase('small_phase') do
        Array.new(10) { |i| "item-#{i}" }
        :ok
      end

      expect(result).to eq(:ok)
      expect(elapsed).to be >= 0.0

      report.measure_phase('alloc_heavy') do
        Array.new(500) { |i| "allocated-string-#{i}" }
      end

      total_elapsed = report.finish(extractor_timings: { 'models' => 0.125, 'controllers' => 0.05 })

      expect(total_elapsed).to be >= 0.0
      data = report.to_h

      expect(data[:schema_version]).to eq(1)
      expect(data[:operation]).to eq('full')
      expect(data[:woods_version]).to eq(Woods::VERSION)
      expect(data[:ruby_version]).to eq(RUBY_VERSION)
      expect(data[:pid]).to eq(Process.pid)
      expect(data[:extractor_timings]).to eq({ 'models' => 0.125, 'controllers' => 0.05 })

      expect(data[:total][:status]).to eq('ok')
      expect(data[:total][:error_class]).to be_nil
      expect(data[:total][:wall_ms]).to be >= 0.0
      expect(data[:total][:cpu_ms]).to be >= 0.0
      expect(data[:total][:allocations]).to be >= 500
      expect(data[:total][:gc_count]).to be >= 0
      expect(data[:total][:heap_live_slots]).to be > 0

      expect(data[:phases].map { |p| p[:name] }).to eq(%w[small_phase alloc_heavy])
      heavy = data[:phases].last
      expect(heavy[:allocations]).to be >= 500
      expect(heavy[:wall_ms]).to be >= 0.0
      expect(heavy[:cpu_ms]).to be >= 0.0

      expect(data[:top_phases_by_allocations].first[:name]).to eq('alloc_heavy')
      expect(data[:top_phases_by_wall].map { |p| p[:name] }).to contain_exactly('small_phase', 'alloc_heavy')
    end

    it 'records failed status and error class when finished with an error' do
      report = described_class.new(operation: 'incremental').start
      report.finish(error: IOError.new('disk full'))

      expect(report.to_h[:total][:status]).to eq('error')
      expect(report.to_h[:total][:error_class]).to eq('IOError')
    end

    it 'writes valid JSON atomically via #write_json' do
      report = described_class.new(operation: 'full').start
      report.measure_phase('graph rebuild') { :done }
      report.finish

      out_path = File.join(tmpdir, 'nested', 'profile.json')
      report.write_json(out_path)

      parsed = JSON.parse(File.read(out_path))
      expect(parsed['operation']).to eq('full')
      expect(parsed['phases'].map { |p| p['name'] }).to eq(['graph rebuild'])
      expect(parsed['total']['status']).to eq('ok')
    end

    it 'renders a human-readable summary table' do
      report = described_class.new(operation: 'full').start
      report.measure_phase('extraction') { Array.new(200) { 'x' } }
      report.finish

      table = report.summary_table
      expect(table).to include('Woods Profile (full, status: ok)')
      expect(table).to include('extraction')
      expect(table).to include('wall_ms')
      expect(table).to include('allocations')
    end
  end

  describe 'Woods::Extractor integration with WOODS_PROFILE_OUT' do
    let(:rails_root) { Pathname.new(tmpdir) }
    let(:logged) { [] }
    let(:logger) do
      instance_double(Logger).tap do |log|
        allow(log).to receive(:info) { |message| logged << message.to_s }
        allow(log).to receive(:warn) { |message| logged << "WARN: #{message}" }
        allow(log).to receive(:error)
        allow(log).to receive(:debug)
      end
    end
    let(:extractor) { Woods::Extractor.new(output_dir: File.join(tmpdir, 'output')) }

    before do
      stub_const('Rails', double('Rails'))
      allow(Rails).to receive(:root).and_return(rails_root)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(Rails).to receive(:version).and_return('8.0.0')
      @original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      Woods.configuration.concurrent_extraction = false
      Woods.configuration.precompute_flows = false
      allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_return(:syncfs)
      %i[setup_output_directory safe_eager_load! extract_all_sequential withdraw_disabled_flows
         deduplicate_results annotate_packages resolve_dependents enrich_with_git_data
         annotate_graph_with_git_data normalize_file_paths write_results
         sweep_orphaned_unit_files write_dependency_graph write_graph_analysis
         write_manifest write_structural_summary capture_snapshot
         log_summary].each do |phase|
        allow(extractor).to receive(phase)
      end
      allow(Woods::ModelNameCache).to receive(:reset!)
      allow(Woods::GraphAnalyzer).to receive(:new).and_return(double('GraphAnalyzer', analyze: {}))
    end

    after do
      Woods.configuration = @original_config
    end

    it 'populates last_profile and writes JSON when WOODS_PROFILE_OUT is set' do
      profile_path = File.join(tmpdir, 'run-profile.json')
      original_profile = ENV.fetch('WOODS_PROFILE', nil)
      original_out = ENV.fetch('WOODS_PROFILE_OUT', nil)
      ENV['WOODS_PROFILE'] = nil
      ENV['WOODS_PROFILE_OUT'] = profile_path

      extractor.extract_all

      expect(extractor.last_profile).to be_a(described_class)
      expect(File.exist?(profile_path)).to be(true)

      parsed = JSON.parse(File.read(profile_path))
      expect(parsed['operation']).to eq('full')
      expect(parsed['total']['status']).to eq('ok')
      expect(parsed['phases'].map { |p| p['name'] }).to include('source capture', 'extraction', 'write results')
    ensure
      ENV['WOODS_PROFILE'] = original_profile
      ENV['WOODS_PROFILE_OUT'] = original_out
    end

    it 'leaves last_profile nil when neither WOODS_PROFILE nor WOODS_PROFILE_OUT is set' do
      original_profile = ENV.fetch('WOODS_PROFILE', nil)
      original_out = ENV.fetch('WOODS_PROFILE_OUT', nil)
      ENV['WOODS_PROFILE'] = nil
      ENV['WOODS_PROFILE_OUT'] = nil

      extractor.extract_all

      expect(extractor.last_profile).to be_nil
    ensure
      ENV['WOODS_PROFILE'] = original_profile
      ENV['WOODS_PROFILE_OUT'] = original_out
    end
  end
end
