# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/impact/report'

RSpec.describe Woods::Impact::Report, 'typed focus mode' do
  around do |example|
    Dir.mktmpdir('impact-focus') do |root|
      @root = root
      payload = File.join(root, 'payloads', 'gen-1')
      FileUtils.mkdir_p(File.join(payload, 'models'))
      unit = { 'identifier' => 'Example', 'type' => 'model', 'source_code' => nil,
               'metadata' => {}, 'dependencies' => [] }
      filename = "Example_#{Digest::SHA256.hexdigest('Example')[0, 8]}.json"
      File.write(File.join(payload, 'models', filename), JSON.generate(unit))
      File.write(File.join(payload, 'models', '_index.json'), '[{"identifier":"Example"}]')
      File.write(File.join(payload, 'manifest.json'), '{"counts":{"models":1},"total_units":1}')
      File.write(File.join(payload, 'dependency_graph.json'), '{"reverse_via":{},"pagerank":{}}')
      File.write(File.join(root, 'generation.json'), '{"number":1,"token":"one","payload":"payloads/gen-1"}')
      example.run
    end
  end

  it 'uses one captured endpoint, exact typed roots and an explicit empty range' do
    result = described_class.focus(@root, identities: [{ 'identifier' => 'Example', 'type' => 'model' }])
    data = result.to_h
    expect(data['range']).to be_nil
    expect(data.dig('endpoint', 'generation')).to eq(1)
    expect(data.dig('parameters', 'mode')).to eq('focus')
    expect(data['focus']).to eq([{ 'identifier' => 'Example', 'type' => 'model' }])
    expect(data['changed']).to eq([])
    expect(data['unknowns']).to include(include('kind' => 'source_unavailable', 'endpoint' => 'to'))
    expect(data.dig('coverage', 'focus')).to eq('typed_units')
  end

  it 'refuses unknown or untyped selectors instead of silently broadening to unit or method scope' do
    expect { described_class.focus(@root, identities: ['Example']) }.to raise_error(ArgumentError)
    expect do
      described_class.focus(@root, identities: [{ 'identifier' => 'Example#run', 'type' => 'model' }])
    end.to raise_error(Woods::Impact::ResolutionError)
  end
end
