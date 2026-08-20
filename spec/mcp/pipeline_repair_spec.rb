# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/coordination/pipeline_lock'
require 'woods/mcp/server'
require 'woods/operator/pipeline_guard'

RSpec.describe 'Index MCP pipeline repair contract' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:state_dir) { Dir.mktmpdir('woods-mcp-repair') }
  let(:lock_path) { File.join(state_dir, 'extraction.lock') }
  let(:repair_lock) do
    Woods::Coordination::PipelineLock.new(
      lock_dir: state_dir, name: 'extraction', stale_timeout: 60
    )
  end
  let(:guard) { Woods::Operator::PipelineGuard.new(state_dir: state_dir, cooldown: 300) }
  let(:server) do
    Woods::MCP::Server.build(
      index_dir: fixture_dir,
      operator: { pipeline_lock: repair_lock, pipeline_guard: guard },
      response_format: :json,
      warmup: false
    )
  end

  after { FileUtils.rm_rf(state_dir) }

  it 'refuses to clear an active lock and preserves its owner' do
    holder = Woods::Coordination::PipelineLock.new(
      lock_dir: state_dir, name: 'extraction', stale_timeout: 60
    )
    expect(holder.acquire).to be(true)
    token = JSON.parse(File.read(lock_path)).fetch('token')

    result = repair('clear_locks')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('lock_active')
    expect(result.dig('_meta', 'action')).to eq('clear_locks')
    expect(JSON.parse(File.read(lock_path)).fetch('token')).to eq(token)
  ensure
    holder&.release
  end

  it 'clears a genuinely stale lock and reports the real repair' do
    holder = Woods::Coordination::PipelineLock.new(
      lock_dir: state_dir, name: 'extraction', stale_timeout: 60
    )
    expect(holder.acquire).to be(true)
    File.utime(Time.now - 120, Time.now - 120, lock_path)

    result = repair('clear_locks')

    expect(result['isError']).to be(false)
    expect(result.dig('structuredContent', 'data')).to eq(
      'repaired' => true, 'action' => 'clear_locks', 'outcome' => 'cleared'
    )
    expect(File.exist?(lock_path)).to be(false)
  ensure
    holder&.release
  end

  it 'preserves a fresh successor that wins the stale retirement race' do
    holder = Woods::Coordination::PipelineLock.new(
      lock_dir: state_dir, name: 'extraction', stale_timeout: 60
    )
    expect(holder.acquire).to be(true)
    File.utime(Time.now - 120, Time.now - 120, lock_path)
    successor_token = 'mcp-race-successor'
    original_rename = File.method(:rename)
    raced = false

    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(lock_path, kind_of(String)) do |source, destination|
      unless raced
        raced = true
        retired = "#{lock_path}.raced-stale"
        original_rename.call(source, retired)
        File.write(source, JSON.generate(pid: Process.pid, token: successor_token))
        FileUtils.rm_f(retired)
      end
      original_rename.call(source, destination)
    end

    result = repair('clear_locks')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('lock_active')
    expect(JSON.parse(File.read(lock_path)).fetch('token')).to eq(successor_token)
  end

  it 'reports a missing lock as a stable no-op error' do
    result = repair('clear_locks')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('lock_missing')
    expect(result.dig('_meta', 'action')).to eq('clear_locks')
    expect(result.dig('structuredContent', 'data')).to be_nil
  end

  it 'resets real cooldowns and allows both pipeline operations immediately' do
    guard.record!(:extraction)
    guard.record!(:embedding)
    guard.record!(:custom_operation)
    expect(guard.allow?(:extraction)).to be(false)
    expect(guard.allow?(:embedding)).to be(false)

    result = repair('reset_cooldowns')

    expect(result['isError']).to be(false)
    expect(result.dig('structuredContent', 'data')).to eq(
      'repaired' => true, 'action' => 'reset_cooldowns', 'outcome' => 'reset'
    )
    expect(guard.allow?(:extraction)).to be(true)
    expect(guard.allow?(:embedding)).to be(true)
    expect(guard.allow?(:custom_operation)).to be(false)
  end

  it 'reports absent cooldown state as a stable no-op error' do
    result = repair('reset_cooldowns')

    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('cooldown_state_missing')
    expect(result.dig('_meta', 'action')).to eq('reset_cooldowns')
    expect(result.dig('structuredContent', 'data')).to be_nil
  end

  def repair(action)
    request = {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'pipeline_repair',
        arguments: { action: action },
        _meta: {
          'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
          'io.modelcontextprotocol/clientInfo' => { 'name' => 'repair-spec', 'version' => '1.0' },
          'io.modelcontextprotocol/clientCapabilities' => {}
        }
      }
    }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end
end
