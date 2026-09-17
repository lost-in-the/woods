# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/service_extractor'
require 'woods/extractors/configuration_extractor'
require 'woods/source_inputs/consumer_errors'

RSpec.describe Woods::SourceInputs::ConsumerErrors do
  include_context 'extractor setup'

  it 'distinguishes a handled empty result from a successful negative match on separate consumers' do
    file = create_file('app/services/pay.rb', 'class Pay; def call; end; end')
    failed = Woods::Extractors::ServiceExtractor.new
    unaffected = Woods::Extractors::ServiceExtractor.new
    allow(failed).to receive(:extract_metadata).and_raise(IOError, 'fixture metadata failure')
    expect(logger).to receive(:error).with("Failed to extract service #{file}: fixture metadata failure")

    results = [failed, unaffected].map { |consumer| Thread.new { consumer.extract_all } }.map(&:value)
    expect(results.first).to eq([])
    expect(results.last.map(&:identifier)).to eq(['Pay'])
    expect(described_class.failed?(failed)).to be(true)
    expect(described_class.failed?(unaffected)).to be(false)

    File.write(file, "module Pay\nend\n")
    expect(unaffected.extract_all).to eq([])
    expect(described_class.failed?(unaffected)).to be(false)
  end

  it 'propagates a nested behavioral profile failure without changing its result' do
    consumer = Woods::Extractors::ConfigurationExtractor.new
    profiler = Woods::Extractors::BehavioralProfile.new
    allow(Woods::Extractors::BehavioralProfile).to receive(:new).and_return(profiler)
    allow(profiler).to receive(:extract) do
      described_class.record(profiler)
      nil
    end
    expect(consumer.extract_all).to eq([])
    expect(described_class.failed?(consumer)).to be(true)
  end
end
