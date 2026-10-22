# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/impact/report'
require 'woods/impact/task'

RSpec.describe 'woods:impact' do
  let(:environment_keys) { %w[WOODS_OUTPUT FORMAT FOCUS AT WOODS_IMPACT_OPTIONS] }

  around do |example|
    previous_rake = Rake.application
    previous_env = environment_keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    previous_out = $stdout
    previous_err = $stderr
    Dir.mktmpdir('impact-rake') do |dir|
      @root = dir
      environment_keys.each { |key| ENV.delete(key) }
      ENV['WOODS_OUTPUT'] = dir
      @out = $stdout = StringIO.new
      @err = $stderr = StringIO.new
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment) { raise 'must not boot Rails' }
      load File.expand_path('../../lib/tasks/woods.rake', __dir__)
      publish(1, 'before')
      publish(2, 'after')
      example.run
    end
  ensure
    Rake.application = previous_rake
    previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    $stdout = previous_out
    $stderr = previous_err
  end

  def publish(number, source)
    payload = File.join(@root, 'payloads', "gen-#{number}")
    FileUtils.mkdir_p(File.join(payload, 'models'))
    unit = { 'identifier' => 'Example', 'type' => 'model', 'source_code' => source,
             'metadata' => {}, 'dependencies' => [] }
    name = "Example_#{Digest::SHA256.hexdigest('Example')[0, 8]}.json"
    File.write(File.join(payload, 'models', name), JSON.generate(unit))
    File.write(File.join(payload, 'models', '_index.json'), '[{"identifier":"Example"}]')
    File.write(File.join(payload, 'manifest.json'), '{"counts":{"models":1},"total_units":1}')
    File.write(File.join(payload, 'dependency_graph.json'), '{"reverse_via":{},"pagerank":{}}')
    File.write(File.join(@root, 'generation.json'), JSON.generate('number' => number, 'token' => "n#{number}",
                                                                  'payload' => "payloads/gen-#{number}"))
  end

  def invoke(*args)
    Rake::Task['woods:impact'].invoke(*args)
  end

  def saved_paths
    Dir[File.join(@root, 'explorer', 'impacts', '*', 'impact.json')]
  end

  it 'has no Rails prerequisite, computes once, saves JSON and prints only the requested report' do
    ENV['FORMAT'] = 'json'
    expect(Rake::Task['woods:impact'].prerequisites).to eq([])
    expect(Woods::Impact::Report).to receive(:compare).once.and_call_original
    invoke('gen:1')
    expect(saved_paths.size).to eq(1)
    expect(File.binread(saved_paths.first)).to eq(@out.string)
    expect(JSON.parse(@out.string).dig('range', 'to', 'generation')).to eq(2)
    expect(@err.string).to include('Saved impact report', saved_paths.first)
  end

  %w[markdown mermaid].each do |format|
    it "renders #{format} from the computed report and saves the same immutable JSON" do
      ENV['FORMAT'] = format
      invoke('gen:1', 'gen:2')
      expect(@out.string).to start_with(format == 'markdown' ? '## Change impact' : 'flowchart LR')
      expect(JSON.parse(File.binread(saved_paths.first))['schema_version']).to eq(1)
      expect(@out.string).not_to include('Saved impact report')
    end
  end

  it 'uses configured output_dir as a lazy fallback without loading environment' do
    ENV.delete('WOODS_OUTPUT')
    allow(Woods).to receive(:configuration).and_return(double(output_dir: @root))
    invoke('gen:1')
    expect(saved_paths.size).to eq(1)
    expect(@out.string).to start_with('## Change impact')
  end

  it 'supports exact typed focus and AT without fabricating a range' do
    ENV['FORMAT'] = 'json'
    ENV['FOCUS'] = '[{"identifier":"Example","type":"model"}]'
    ENV['AT'] = 'gen:1'
    ENV['WOODS_IMPACT_OPTIONS'] = '{"depth":0,"via":["render"]}'
    expect(Woods::Impact::Report).to receive(:focus).once.and_call_original
    invoke
    data = JSON.parse(@out.string)
    expect(data['range']).to be_nil
    expect(data.dig('endpoint', 'generation')).to eq(1)
    expect(data.dig('parameters', 'depth')).to eq(0)
    expect(data['focus']).to eq([{ 'identifier' => 'Example', 'type' => 'model' }])
  end

  it 'does not save or print a report when rendering fails' do
    expect(Woods::Impact::Renderers).to receive(:markdown).and_raise(ArgumentError, 'Cannot render report')
    expect { invoke('gen:1') }.to raise_error(ArgumentError, 'Cannot render report')
    expect(saved_paths).to eq([])
    expect(@out.string).to eq('')
    expect(@err.string).to eq('')
  end

  it 'does not save or print a report when a required generation is missing' do
    expect { invoke('gen:3') }.to raise_error(Woods::Impact::ResolutionError)
    expect(saved_paths).to eq([])
    expect(@out.string).to eq('')
    expect(@err.string).to eq('')
  end

  it 'does not save or print a report when a required endpoint is corrupt' do
    File.write(File.join(@root, 'payloads', 'gen-1', 'manifest.json'), '{ invalid')
    expect { invoke('gen:1') }.to raise_error(JSON::ParserError)
    expect(saved_paths).to eq([])
    expect(@out.string).to eq('')
    expect(@err.string).to eq('')
  end

  it 'does not print a rendered report when saving fails' do
    saved_store = instance_double(Woods::Impact::Store)
    allow(Woods::Impact::Store).to receive(:new).and_return(saved_store)
    expect(saved_store).to receive(:save).and_raise(Woods::Impact::Store::Error, 'Cannot save report')
    expect { invoke('gen:1') }.to raise_error(Woods::Impact::Store::Error, 'Cannot save report')
    expect(saved_paths).to eq([])
    expect(@out.string).to eq('')
    expect(@err.string).to eq('')
  end

  [
    [{ 'FORMAT' => 'html' }, ['gen:1']],
    [{}, []],
    [{ 'AT' => 'now' }, ['gen:1']],
    [{ 'FOCUS' => '[]' }, ['gen:1']],
    [{ 'FOCUS' => '["Example"]' }, []],
    [{ 'WOODS_IMPACT_OPTIONS' => '[]' }, ['gen:1']],
    [{ 'WOODS_IMPACT_OPTIONS' => '{"unrecognized":1}' }, ['gen:1']]
  ].each_with_index do |(env, args), index|
    it "rejects invalid inputs before computing or saving (case #{index + 1})" do
      env.each { |key, value| ENV[key] = value }
      expect(Woods::Impact::Report).not_to receive(:compare)
      expect(Woods::Impact::Report).not_to receive(:focus)
      expect { invoke(*args) }.to raise_error(ArgumentError)
      expect(saved_paths).to eq([])
      expect(@out.string).to eq('')
    end
  end
end
