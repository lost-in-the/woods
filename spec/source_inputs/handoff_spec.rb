# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/source_inputs/handoff'
require 'woods/source_inputs/scanner'

RSpec.describe Woods::SourceInputs::Handoff do
  around do |example|
    Dir.mktmpdir('woods-handoff') do |root|
      @root = root
      @output = File.join(root, 'index')
      @path = File.join(root, 'handoff.json')
      @key = Woods::SourceInputs::PrivateKey.new(output_dir: @output, create: true)
      @rules = Woods::SourceInputs::Scopes.new
      @snapshot = Woods::SourceInputs::Scanner.new(root: root, output_dir: @output, key: @key, scopes: @rules).call
      @data = { 'version' => 1, 'nonce' => 'a' * 64, 'root' => root, 'output' => @output,
                'operation' => 'full', 'rules' => @rules.fingerprint, 'launcher_pid' => Process.ppid,
                'snapshot' => @snapshot }
      previous = ENV.fetch(described_class::ENV_KEY, nil)
      prepare
      example.run
    ensure
      ENV[described_class::ENV_KEY] = previous
    end
  end

  def prepare
    File.write(@path, JSON.generate(@data), mode: 'w', perm: 0o600)
    ENV[described_class::ENV_KEY] = JSON.generate(path: @path, nonce: 'a' * 64)
  end

  def read(**overrides)
    described_class.read(root: @root, output_dir: @output, operation: 'full',
                         rules: @rules.fingerprint, key_id: @key.identifier, **overrides)
  end

  it 'accepts a matching private parent handoff once in its child process' do
    expect(read).to eq(@snapshot)
    expect(read).to be_nil
  end

  it 'rejects a different root, output, operation, rule set, key or process parent' do
    [{ root: '/elsewhere' }, { output_dir: '/elsewhere' }, { operation: 'incremental' },
     { rules: 'b' * 64 }, { key_id: 'b' * 64 }].each { |options| expect(read(**options)).to be_nil }
    @data['launcher_pid'] = -1
    prepare
    expect(read).to be_nil
  end

  it 'rejects stale nonces, unsafe files and malformed scope paths' do
    @data['nonce'] = 'b' * 64
    prepare
    expect(read).to be_nil
    @data['nonce'] = 'a' * 64
    prepare
    File.chmod(0o644, @path)
    expect(read).to be_nil
    File.chmod(0o600, @path)
    @data['snapshot']['files'] = { '../outside' => 'c' * 64 }
    @data['snapshot']['scope_paths'] = { 'boot' => ['../outside'] }
    prepare
    expect(read).to be_nil
  end

  it 'does not block on a FIFO or trust a symlink handoff' do
    File.rename(@path, "#{@path}.actual")
    File.symlink("#{@path}.actual", @path)
    expect(read).to be_nil
    File.unlink(@path)
    File.mkfifo(@path)
    expect(read).to be_nil
  end
end
