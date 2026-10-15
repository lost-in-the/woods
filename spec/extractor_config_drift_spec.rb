# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Incremental extraction configuration drift' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-config-drift') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  let(:logger) { double('Logger').as_null_object }
  let(:output) { @root.join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }
  let(:synthetic_readers) { [{ constant: 'LanternSettings', file: 'config/lantern.yml' }] }

  before do
    stub_const('Rails', double('Rails', root: @root, logger: logger, version: '8.0.0'))
    allow(extractor).to receive(:safe_eager_load!)
    allow(extractor).to receive(:prepare_source_reference_baseline)
  end

  def baseline(extraction_config: Woods.configuration.extraction_fingerprint)
    directory = Woods::PayloadStore.new(output).create(1)
    manifest = { woods_version: Woods::VERSION, total_units: 0, counts: {} }
    manifest[:extraction_config] = extraction_config if extraction_config
    directory.join('manifest.json').write(JSON.generate(manifest))
    directory.join('dependency_graph.json').write(JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))
    Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
  end

  def artifacts
    Dir.glob(output.join('**/*')).to_h do |path|
      [path.delete_prefix("#{output}/"), File.directory?(path) ? :directory : File.binread(path)]
    end
  end

  def written_manifest
    allow(Time).to receive(:current).and_return(Time.now)
    provenance = instance_double(Woods::GitProvenance, to_h: { git_branch: 'main', git_sha: 'abc' })
    allow(Woods::GitProvenance).to receive(:new).and_return(provenance)
    extractor.send(:write_manifest, incremental: true)
    JSON.parse(extractor.send(:payload_dir).join('manifest.json').read)
  end

  describe 'Configuration#extraction_fingerprint' do
    it 'digests every extraction-shaping key without exposing a value' do
      Woods.configuration.settings_readers = synthetic_readers
      fingerprint = Woods.configuration.extraction_fingerprint

      expect(fingerprint.keys).to eq(Woods::Configuration::EXTRACTION_KEYS.map(&:to_s))
      expect(fingerprint.values).to all(match(/\A\h{64}\z/))
      expect(JSON.generate(fingerprint)).not_to include('LanternSettings', 'lantern.yml')
    end

    it 'changes only the digest of the key whose value changed' do
      before = Woods.configuration.extraction_fingerprint
      Woods.configuration.settings_readers = synthetic_readers
      after = Woods.configuration.extraction_fingerprint

      expect(before.keys.reject { |key| before[key] == after[key] }).to eq(['settings_readers'])
    end

    it 'distinguishes event patterns by regexp options, not only by source' do
      pattern = ->(regexp) { [{ role: :publisher, pattern: regexp, system: :lantern }] }
      Woods.configuration.event_patterns = pattern.call(/Lantern\.emit\(:(\w+)/)
      plain = Woods.configuration.extraction_fingerprint['event_patterns']
      Woods.configuration.event_patterns = pattern.call(/Lantern\.emit\(:(\w+)/i)

      expect(Woods.configuration.extraction_fingerprint['event_patterns']).not_to eq(plain)
    end

    it 'ignores the order a consumer declaration was written in' do
      Woods.configuration.external_table_consumers = { 'lantern-shop' => %w[wicks], 'lantern-site' => %w[oils] }
      first = Woods.configuration.extraction_fingerprint
      Woods.configuration.external_table_consumers = { 'lantern-site' => %w[oils], 'lantern-shop' => %w[wicks] }

      expect(Woods.configuration.extraction_fingerprint).to eq(first)
    end
  end

  %w[incremental refresh].each do |operation|
    describe "#{operation} preparation" do
      it 'runs when the configuration matches the baseline' do
        baseline

        expect { extractor.send(:prepare_incremental_run, operation: operation) }.not_to raise_error
        expect(logger).not_to have_received(:warn)
      end

      it 'refuses a changed key by name, without its value, before creating a payload' do
        baseline
        previous = artifacts
        Woods.configuration.settings_readers = synthetic_readers

        expect { extractor.send(:prepare_incremental_run, operation: operation) }
          .to raise_error(Woods::ExtractionError) { |error|
            expect(error.message).to match(/settings_readers.*woods:extract/m)
            expect(error.message).not_to include('LanternSettings', 'lantern.yml')
          }
        expect(artifacts).to eq(previous)
      end

      it 'warns and runs over a baseline published before the fingerprint existed' do
        baseline(extraction_config: nil)

        expect { extractor.send(:prepare_incremental_run, operation: operation) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/configuration fingerprint.*woods:extract/m)
      end

      it 'warns and runs when the baseline predates a fingerprinted key' do
        recorded = Woods.configuration.extraction_fingerprint.except('test_subdomain_helpers')
        baseline(extraction_config: recorded)

        expect { extractor.send(:prepare_incremental_run, operation: operation) }.not_to raise_error
        expect(logger).to have_received(:warn).with(/test_subdomain_helpers/)
      end

      it 'ignores a key the baseline recorded that this version no longer fingerprints' do
        baseline(extraction_config: Woods.configuration.extraction_fingerprint.merge('retired_key' => '0' * 64))

        expect { extractor.send(:prepare_incremental_run, operation: operation) }.not_to raise_error
        expect(logger).not_to have_received(:warn)
      end
    end
  end

  it 'refuses woods:refresh the same way through the public entry point' do
    baseline
    Woods.configuration.test_support_paths = ['spec/lantern/**/*.rb']

    expect { extractor.refresh(:models) }.to raise_error(Woods::ExtractionError, /test_support_paths/)
  end

  describe 'the published manifest' do
    it 'records the current fingerprint on a full run' do
      allow(Time).to receive(:current).and_return(Time.now)
      allow(Woods::GitProvenance).to receive(:new)
        .and_return(instance_double(Woods::GitProvenance, to_h: { git_branch: 'main', git_sha: 'abc' }))
      output.mkpath
      extractor.instance_variable_set(:@results, {})
      extractor.send(:write_manifest)

      manifest = JSON.parse(output.join('manifest.json').read)
      expect(manifest['extraction_config']).to eq(Woods.configuration.extraction_fingerprint)
    end

    it "carries the baseline's fingerprint through an incremental run" do
      recorded = Woods.configuration.extraction_fingerprint.merge('retired_key' => '0' * 64)
      baseline(extraction_config: recorded)
      extractor.send(:prepare_incremental_run)

      expect(written_manifest['extraction_config']).to eq(recorded)
    end

    it 'leaves a pre-fingerprint baseline unfingerprinted until a full run' do
      baseline(extraction_config: nil)
      extractor.send(:prepare_incremental_run)

      expect(written_manifest).not_to have_key('extraction_config')
    end
  end
end
