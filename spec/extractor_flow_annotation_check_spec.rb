# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'

# When the unchanged check may leave a controller's `metadata.flow_paths` out
# of its comparison (#994). The fresh unit never carries the annotation at
# that point, so comparing it made every flow-bearing controller look changed.
# Leaving it out is safe only when the run's flow refresh reconciles it.
#
# | unit type  | precompute_flows | published flow family | annotation left out |
# |------------|------------------|-----------------------|---------------------|
# | controller | true             | present               | yes                 |
# | controller | :best_effort     | present               | yes                 |
# | controller | false            | present               | no                  |
# | controller | true             | flows/ missing        | no (unknown)        |
# | controller | true             | flows/ empty          | no (unknown)        |
# | model      | true             | present               | no                  |
RSpec.describe Woods::Extractor, 'flow annotation in the unchanged check' do
  let(:tmpdir) { Dir.mktmpdir('woods_flow_annotation') }
  let(:output_dir) { File.join(tmpdir, 'output') }
  let(:extractor) { described_class.new(output_dir: output_dir) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
    allow(Rails).to receive(:logger).and_return(instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil))
    @original_config = Woods.configuration
    Woods.configuration = Woods::Configuration.new
  end

  after do
    Woods.configuration = @original_config
    FileUtils.rm_rf(tmpdir)
  end

  def unit_of(type)
    Woods::ExtractedUnit.new(type: type, identifier: 'LedgersController', file_path: 'app/controllers/x.rb')
  end

  def publish_flow_family(state)
    flows = File.join(output_dir, 'flows')
    return if state == :missing

    FileUtils.mkdir_p(flows)
    File.write(File.join(flows, 'flow_index.json'), '{}') if state == :present
  end

  [
    [:controller, true, :present, true],
    [:controller, :best_effort, :present, true],
    [:controller, false, :present, false],
    [:controller, true, :missing, false],
    [:controller, true, :empty, false],
    [:model, true, :present, false]
  ].each do |type, gate, family, expected|
    it "is #{expected} for a #{type} with precompute_flows #{gate.inspect} and a #{family} flow family" do
      Woods.configuration.precompute_flows = gate
      publish_flow_family(family)

      expect(extractor.send(:flow_annotation_reconciled?, unit_of(type))).to be(expected)
    end
  end
end
