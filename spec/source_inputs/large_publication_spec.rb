# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'
require 'woods/source_inputs/status'
require 'woods/resilience/index_validator'
require 'woods/mcp/server'

RSpec.describe 'Oversized source evidence publication' do
  it 'publishes a usable generation for 45,000 real source files without a scan-budget confound' do
    Dir.mktmpdir('woods-large-source') do |root|
      output = File.join(root, 'index')
      directories = %w[app/models app/services lib].map do |prefix|
        File.join(root, prefix, 'nested_namespace_directory/another_level').tap { |path| FileUtils.mkdir_p(path) }
      end
      45_000.times do |index|
        path = File.join(directories[index % 3], "file_number_#{index}_abcdefgh_long_descriptive_name.rb")
        File.write(path, "class F#{index}; end\n")
      end
      stub_const('Rails', double(root: Pathname.new(root), logger: double.as_null_object))
      # Keep the production byte/file limits; scheduling load must not turn this
      # serialization regression into a scan-time-budget test.
      allow(Woods::SourceInputs::Scanner).to receive(:new).and_wrap_original do |original, **options|
        original.call(**options, max_seconds: 120)
      end
      extractor = Woods::Extractor.new(output_dir: output)
      extractor.send(:begin_source_inputs, 'full')
      snapshot = extractor.instance_variable_get(:@source_inputs).instance_variable_get(:@snapshot)
      expect(snapshot).to include('complete' => true, 'errors' => [])
      expect(snapshot['files'].size).to eq(45_000)
      extractor.send(:begin_payload!)
      extractor.instance_variable_set(:@eager_load_complete, true)
      File.write(extractor.payload_dir.join('manifest.json'), JSON.generate(counts: {}, total_units: 0))
      extractor.send(:write_dependency_graph)

      expect { extractor.send(:publish_generation, 'full') }
        .to output(/source_manifest_too_large.*bytes.*16777216/).to_stderr
      expect { extractor.raise_on_publication_failure! }.not_to raise_error
      payload = Woods::Generation.new(output_dir: output).payload_dir
      bytes = File.binread(payload.join('source_inputs.json'))
      evidence = Woods::SourceInputs::Manifest.parse(bytes)
      expect(bytes.bytesize).to be < 2000
      expect(evidence.data['unavailable']['size_bytes']).to be > Woods::SourceInputs::Manifest::MAX_BYTES
      expect(evidence.data['errors']).to be_empty
      status = Woods::SourceInputs::Status.new(output_dir: output).call
      expect(status).to include('state' => 'unavailable', 'reasons' => ['source_manifest_too_large'])
      expect(status['recommendations']).not_to include('fresh_capture')
      report = Woods::Resilience::IndexValidator.new(index_dir: output).validate
      expect(report.valid?).to be(true), report.errors.inspect
      expect(report.warnings.join).to include('source_manifest_too_large')
      reader = Woods::MCP::IndexReader.new(output)
      mcp = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: output)
      expect(mcp.dig(:index, :source_freshness)).to include('state' => 'unavailable', 'complete' => false)
    end
  end
end
