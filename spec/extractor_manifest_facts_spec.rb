# frozen_string_literal: true

# Pins manifest bytes, provenance authority and external acquisition order.
require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'active_support/core_ext/time'

RSpec.describe 'Extractor manifest data composition' do
  include_context 'isolated Woods runtime'

  let(:output) { Pathname.new(@root).join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }
  let(:events) { [] }
  let(:full_config) { { 'full_key' => 'full_digest' } }
  let(:baseline_config) { { 'baseline_key' => 'baseline_digest' } }
  let(:summary) { { 'state' => 'available', 'head_sha' => 'capture', 'capture' => { 'retained' => 2 } } }
  let(:provenance) { { git_sha: 'capture', git_branch: 'main' } }
  let(:expected) do
    {
      extracted_at: '2026-10-27T12:00:00Z', woods_version: 'contract-version',
      rails_version: 'contract-rails', ruby_version: RUBY_VERSION,
      counts: { models: 2, controllers: 0 }, total_units: 2, total_chunks: 3,
      git_sha: 'capture', git_branch: 'main', gemfile_lock_sha: nil, schema_sha: 'schema',
      extraction_config: full_config, git_enrichment: summary
    }
  end

  around do |example|
    Dir.mktmpdir('woods-manifest-facts') do |root|
      @root = root
      example.run
    end
  end

  before do
    stub_const('Woods::VERSION', 'contract-version')
    logger = double('Logger').as_null_object
    stub_const('Rails', double('Rails', root: Pathname.new(@root), logger: logger))
    allow(Rails).to receive(:version) {
      events << :rails_version
      'contract-rails'
    }
    clock = double('ClockValue', iso8601: '2026-10-27T12:00:00Z')
    allow(Time).to receive(:current) {
      events << :timestamp
      clock
    }
    allow(Woods.configuration).to receive(:extraction_fingerprint) {
      events << :configuration
      full_config
    }
    git = instance_double(Woods::GitProvenance, to_h: provenance)
    allow(Woods::GitProvenance).to receive(:new).with(root: Pathname.new(@root)) do
      events << :provenance
      git
    end
    filter = instance_double(Woods::GitSourceFilter)
    allow(Woods::GitSourceFilter).to receive(:new).with(root: Pathname.new(@root)).and_return(filter)
    allow(filter).to receive(:available?) {
      events << :git_filter
      true
    }
    allow(extractor).to receive(:gemfile_lock_sha) {
      events << :lock_digest
      nil
    }
    allow(extractor).to receive(:schema_sha) {
      events << :schema_digest
      'schema'
    }
    allow(extractor).to receive(:git_enrichment_summary) { |**_arguments|
      events << :git_summary
      summary
    }
    allow(extractor).to receive(:json_serialize).and_wrap_original do |method, *arguments|
      events << :serialize
      method.call(*arguments)
    end
    extractor.instance_variable_set(:@results,
                                    { models: [Struct.new(:chunks).new([1, 2]), Struct.new(:chunks).new([1])],
                                      controllers: [] })
    FileUtils.mkdir_p(output)
  end

  [false, true].each do |pretty|
    it "characterizes complete #{pretty ? 'pretty' : 'compact'} full manifest bytes" do
      Woods.configuration.pretty_json = pretty

      extractor.send(:write_manifest)

      expected_bytes = pretty ? JSON.pretty_generate(expected) : JSON.generate(expected)
      expect(Woods::AtomicFile.read(output.join('manifest.json'))).to eq(expected_bytes)
      expect(extractor).to have_received(:git_enrichment_summary).with(refreshed: :all)
      expect(events).to eq(%i[provenance timestamp rails_version lock_digest schema_digest configuration
                              git_summary git_filter serialize])
    end
  end

  it 'uses persisted counts and baseline configuration despite partial nonempty in-memory results' do
    FileUtils.mkdir_p(output.join('models'))
    FileUtils.mkdir_p(output.join('controllers'))
    File.write(output.join('models/_index.json'), JSON.generate([{ chunk_count: 2 }, { chunk_count: 1 }]))
    File.write(output.join('controllers/_index.json'), JSON.generate([]))
    extractor.instance_variable_set(:@results, { models: [Struct.new(:chunks).new([1])] })
    extractor.instance_variable_set(:@baseline_extraction_config, baseline_config)
    allow(extractor).to receive(:persisted_counts).and_wrap_original do |method|
      events << :persisted_counts
      method.call
    end
    Woods.configuration.pretty_json = false

    extractor.send(:write_manifest, incremental: true)

    # Persisted directory reads are sorted; this differs from the full result order.
    expected[:counts] = { controllers: 0, models: 2 }
    expected[:extraction_config] = baseline_config
    expect(Woods::AtomicFile.read(output.join('manifest.json'))).to eq(JSON.generate(expected))
    expect(Woods.configuration).not_to have_received(:extraction_fingerprint)
    expect(extractor).to have_received(:git_enrichment_summary).with(refreshed: Set.new)
    expect(events).to eq(%i[provenance persisted_counts timestamp rails_version lock_digest schema_digest
                            git_summary git_filter serialize])
  end

  it 'omits missing baseline configuration and preserves history-unavailable filtering facts' do
    extractor.instance_variable_set(:@baseline_extraction_config, nil)
    allow(extractor).to receive(:persisted_counts).and_return([{}, 0])
    unavailable = { 'state' => 'unavailable', 'reason' => 'history_read_failed', 'head_sha' => nil }
    allow(extractor).to receive(:git_enrichment_summary).and_return(unavailable)
    filter = instance_double(Woods::GitSourceFilter, available?: false)
    allow(Woods::GitSourceFilter).to receive(:new).and_return(filter)
    Woods.configuration.pretty_json = false

    extractor.send(:write_manifest, incremental: true)

    expected[:counts] = {}
    expected[:total_units] = 0
    expected[:total_chunks] = 0
    expected.delete(:extraction_config)
    expected[:git_enrichment] = unavailable
    expected[:metadata] = { git_filter: 'unavailable' }
    expect(Woods::AtomicFile.read(output.join('manifest.json'))).to eq(JSON.generate(expected))
  end

  it 'keeps an earlier source-digest failure ahead of configuration, Git summary, filtering and writes' do
    allow(extractor).to receive(:schema_sha).and_raise(IOError, 'schema unreadable')

    expect { extractor.send(:write_manifest) }.to raise_error(IOError, 'schema unreadable')
    expect(Woods.configuration).not_to have_received(:extraction_fingerprint)
    expect(extractor).not_to have_received(:git_enrichment_summary)
    expect(output.join('manifest.json')).not_to exist
  end

  [false, true].each do |incremental|
    it "uses captured revision and branch for #{incremental ? 'incremental' : 'full'} manifest output" do
      extractor.instance_variable_set(:@git_capture_head, 'a' * 40)
      extractor.instance_variable_set(:@git_capture_branch, 'captured-branch')
      captured_summary = { 'state' => 'available', 'head_sha' => 'a' * 40,
                           'capture' => { 'refreshed' => 0, 'retained' => 2 } }
      allow(extractor).to receive(:git_enrichment_summary) do |**_arguments|
        events << :git_summary
        captured_summary
      end
      # These differ from the established run capture. Reading them would be a
      # provenance/acquisition regression even if another field later overrode SHA.
      live = instance_double(Woods::GitProvenance,
                             to_h: { git_sha: 'b' * 40, git_branch: 'live-branch' })
      allow(Woods::GitProvenance).to receive(:new).and_return(live)
      if incremental
        extractor.instance_variable_set(:@baseline_extraction_config, baseline_config)
        allow(extractor).to receive(:persisted_counts) do
          events << :persisted_counts
          [{ models: 2, controllers: 0 }, 3]
        end
      end
      Woods.configuration.pretty_json = false

      extractor.send(:write_manifest, incremental: incremental)

      expected[:git_sha] = 'a' * 40
      expected[:git_branch] = 'captured-branch'
      expected[:git_enrichment] = captured_summary
      expected[:extraction_config] = baseline_config if incremental
      expect(Woods::AtomicFile.read(output.join('manifest.json'))).to eq(JSON.generate(expected))
      expect(Woods::GitProvenance).not_to have_received(:new)
      order = []
      order << :persisted_counts if incremental
      order.push(:timestamp, :rails_version, :lock_digest, :schema_digest)
      order << :configuration unless incremental
      order.push(:git_summary, :git_filter, :serialize)
      expect(events).to eq(order)
      refreshed = incremental ? Set.new : :all
      expect(extractor).to have_received(:git_enrichment_summary).with(refreshed: refreshed)
    end
  end

  it 'preserves an unavailable captured branch without substituting the live branch' do
    extractor.instance_variable_set(:@git_capture_head, 'a' * 40)
    extractor.instance_variable_set(:@git_capture_branch, nil)
    Woods.configuration.pretty_json = false

    extractor.send(:write_manifest)

    expected[:git_sha] = 'a' * 40
    expected[:git_branch] = nil
    expect(Woods::AtomicFile.read(output.join('manifest.json'))).to eq(JSON.generate(expected))
    expect(Woods::GitProvenance).not_to have_received(:new)
  end
end
