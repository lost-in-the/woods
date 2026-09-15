# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractor'
require 'tmpdir'

RSpec.describe Woods::Extractor, 'phase accounting' do
  let(:directory) { Dir.mktmpdir('woods-profile') }
  let(:extractor) { described_class.new(output_dir: directory) }
  let(:logger) { double('Logger').as_null_object }

  before do
    stub_const('Rails', double('Rails', logger: logger))
    allow(extractor).to receive(:profiling?).and_return(true)
  end

  after { FileUtils.rm_rf(directory) }

  it 'reports sync, pointer publication and pruning as disjoint phases' do
    marker = double('Marker', number: 2)
    generation = instance_double(Woods::Generation, bump!: marker)
    allow(Woods::Generation).to receive(:new).and_return(generation)
    allow(extractor).to receive(:publishable_payload_name).and_return('payloads/gen-2')
    allow(extractor).to receive(:sync_payload)
    allow(extractor).to receive(:prune_payloads)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0, 2, 2, 5, 5, 10)

    expect(extractor.send(:publish_generation, 'full')).to eq(marker)

    expect(logger).to have_received(:info).with('[Woods] [profile] payload sync in 2s').ordered
    expect(logger).to have_received(:info).with('[Woods] [profile] publish in 3s').ordered
    expect(logger).to have_received(:info).with('[Woods] [profile] payload prune in 5s').ordered
  end

  it 'reports failed run wall time separately from additive phase lines' do
    allow(extractor).to receive(:setup_output_directory).and_raise(IOError, 'fixture failure')
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(10, 14)

    expect { extractor.extract_all }.to raise_error(IOError, 'fixture failure')
    expect(logger).to have_received(:info).with('[Woods] [profile total] full in 4s')
  end

  it 'does not read the timing clock when profiling is disabled' do
    allow(extractor).to receive(:profiling?).and_return(false)
    expect(Process).not_to receive(:clock_gettime)

    expect(extractor.send(:profile_phase, 'example') { :result }).to eq(:result)
  end
end
