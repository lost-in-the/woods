# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'Incremental writer baseline compatibility' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-legacy-baseline') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object))
    allow(extractor).to receive(:safe_eager_load!)
    allow(extractor).to receive(:prepare_source_reference_baseline)
  end

  let(:output) { @root.join('index') }
  let(:extractor) { Woods::Extractor.new(output_dir: output) }

  def baseline(payload:, writer: nil)
    directory = payload ? Woods::PayloadStore.new(output).create(1) : output
    directory.mkpath
    manifest = { total_units: 0, counts: {} }
    manifest[:woods_version] = writer if writer
    directory.join('manifest.json').write(JSON.generate(manifest))
    directory.join('dependency_graph.json').write(JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))
    Woods::Generation.new(output_dir: output).bump!(reason: 'full', payload: payload) if payload
  end

  def artifacts
    Dir.glob(output.join('**/*')).to_h do |path|
      [path.delete_prefix("#{output}/"), File.directory?(path) ? :directory : File.binread(path)]
    end
  end

  %w[incremental refresh].each do |operation|
    [nil, '1.6.3', '2.0.0'].each do |writer|
      it "refuses #{operation} over flat artifacts with writer #{writer.inspect} before creating a payload" do
        baseline(payload: nil, writer: writer)
        previous = artifacts

        expect { extractor.send(:prepare_incremental_run, operation: operation) }
          .to raise_error(Woods::ExtractionError, /legacy.*woods:extract/i)
        expect(artifacts).to eq(previous)
      end
    end

    it "refuses #{operation} over a generation whose manifest names a 1.x writer" do
      baseline(payload: Woods::PayloadStore.name_for(1), writer: '1.6.3')
      previous = artifacts

      expect { extractor.send(:prepare_incremental_run, operation: operation) }
        .to raise_error(Woods::ExtractionError, /1\.6\.3.*woods:extract/)
      expect(artifacts).to eq(previous)
    end
  end

  [nil, '2.0.0.beta1', '2.0.0'].each do |writer|
    it "accepts generation artifacts with writer #{writer.inspect}" do
      baseline(payload: Woods::PayloadStore.name_for(1), writer: writer)

      expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
    end
  end

  it 'keeps an empty directory on the missing-baseline diagnostic rather than classifying it as 1.x' do
    expect { extractor.send(:prepare_incremental_run) }
      .to raise_error(Woods::ExtractionError, /No baseline index found.*woods:extract/)
  end

  it 'does not infer a legacy writer from a bare graph without a manifest' do
    output.mkpath
    output.join('dependency_graph.json').write(JSON.generate(nodes: {}, edges: {}, reverse: {}, file_map: {}))

    expect { extractor.send(:prepare_incremental_run) }.not_to raise_error
  end
end
