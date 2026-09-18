# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/launcher'

RSpec.describe Woods::SourceInputs::Launcher do
  let(:root) { File.expand_path('../..', __dir__) }

  around do |example|
    Dir.mktmpdir('woods-launcher') do |app|
      @app = app
      @output = File.join(app, 'index')
      @record = File.join(app, 'child.json')
      @child = File.join(app, 'child.rb')
      File.write(@child, <<~RUBY)
        require 'json'
        descriptor = JSON.parse(ENV.fetch('WOODS_SOURCE_CAPTURE'))
        capture = JSON.parse(File.read(descriptor.fetch('path')))
        File.write('child.json', JSON.generate(descriptor: descriptor, capture: capture, arguments: ARGV,
                                                output: ENV.fetch('WOODS_OUTPUT'), pid: Process.pid))
        exit Integer(ENV.fetch('WOODS_FIXTURE_EXIT', '0'))
      RUBY
      example.run
    end
  end

  def run_launcher(*args)
    described_class.run(['--root', @app, '--output', @output, *args], command: [RbConfig.ruby, @child])
  end

  def child
    JSON.parse(File.read(@record))
  end

  it 'captures before a fresh child and cleans the private handoff after success' do
    FileUtils.mkdir_p(File.join(@app, 'app/services'))
    File.write(File.join(@app, 'app/services/pay.rb'), 'before boot')
    expect(run_launcher('full')).to eq(0)
    record = child
    expect(record.fetch('pid')).not_to eq(Process.pid)
    expect(record.fetch('capture').fetch('snapshot').fetch('files').keys).to eq(['app/services/pay.rb'])
    expect(record.fetch('arguments')).to eq(['woods:extract'])
    expect(record.fetch('capture')).to include('root' => @app, 'output' => @output, 'operation' => 'full')
    expect(record.fetch('capture').fetch('nonce')).to eq(record.fetch('descriptor').fetch('nonce'))
    expect(File.exist?(record.fetch('descriptor').fetch('path'))).to be(false)
  end

  it 'preserves a JSON incremental path and restart escalation through the hook task' do
    expect(run_launcher('incremental', "app/services/a,b c\nd.rb")).to eq(0)
    record = child
    encoded = record.fetch('arguments').first.split('[', 2).last.delete_suffix(']')
    batch = JSON.parse(Base64.strict_decode64(encoded))
    expect(batch.fetch('events').first.fetch('path')).to eq("app/services/a,b c\nd.rb")
    expect(record.fetch('capture').fetch('operation')).to eq('incremental')
    expect(run_launcher('incremental', 'config/initializers/pay.rb')).to eq(0)
    expect(child.fetch('capture').fetch('operation')).to eq('full')
    expect(child.fetch('arguments').first).to start_with('woods:hook_refresh[')
  end

  it 'validates operation/path arguments before creating output or starting a child' do
    [%w[unknown], %w[full extra], %w[incremental], %w[incremental ../outside.rb],
     %w[refresh unknown], %w[refresh routes,models], %w[--source-root ../outside full]].each do |args|
      expect(run_launcher(*args)).to eq(1)
      expect(File.exist?(@record)).to be(false)
      expect(File.directory?(@output)).to be(false)
    end
  end

  it 'forwards requested refresh types as one validated rake argument' do
    expect(run_launcher('refresh', 'routes', 'controllers')).to eq(0)
    expect(child.fetch('arguments')).to eq(['woods:refresh[routes,controllers]'])
    expect(child.fetch('capture').fetch('operation')).to eq('refresh')
  end

  it 'propagates daemon deferral and failure codes and cleans the handoff' do
    [75, 1].each do |code|
      previous = ENV.fetch('WOODS_FIXTURE_EXIT', nil)
      begin
        ENV['WOODS_FIXTURE_EXIT'] = code.to_s
        expect(run_launcher('incremental', 'app/services/pay.rb')).to eq(code)
      ensure
        ENV['WOODS_FIXTURE_EXIT'] = previous
      end
      expect(File.exist?(child.fetch('descriptor').fetch('path'))).to be(false)
    end
  end
end
