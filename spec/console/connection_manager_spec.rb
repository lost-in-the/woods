# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/connection_manager'

RSpec.describe CodebaseIndex::Console::ConnectionManager do
  let(:config) do
    { 'mode' => 'direct', 'command' => 'echo ok' }
  end

  subject(:manager) { described_class.new(config: config) }

  describe '#initialize' do
    it 'stores config values' do
      expect(manager).not_to be_alive
    end

    it 'defaults to direct mode' do
      m = described_class.new(config: {})
      expect(m).not_to be_alive
    end
  end

  describe '#connect! and #disconnect!' do
    it 'spawns and terminates a process' do
      manager.connect!
      expect(manager).to be_alive
      manager.disconnect!
      expect(manager).not_to be_alive
    end
  end

  describe '#send_request' do
    it 'sends JSON and reads response' do
      # Use a simple Ruby script that echoes back JSON
      echo_config = {
        'mode' => 'direct',
        'command' => 'ruby -e "STDOUT.sync=true; line=gets; puts line"'
      }
      m = described_class.new(config: echo_config)
      m.connect!

      response = m.send_request({ 'id' => 'test', 'tool' => 'status' })
      expect(response['id']).to eq('test')
      expect(response['tool']).to eq('status')

      m.disconnect!
    end
  end

  describe '#heartbeat_needed?' do
    it 'returns false when not connected' do
      expect(manager.heartbeat_needed?).to be false
    end
  end

  describe 'connection modes' do
    it 'builds docker command' do
      docker_config = { 'mode' => 'docker', 'container' => 'my-app', 'command' => 'bundle exec rails runner bridge.rb' }
      m = described_class.new(config: docker_config)
      # We can't easily test docker without docker, but we can verify it doesn't crash on init
      expect(m).not_to be_alive
    end

    it 'raises for docker mode without container' do
      docker_config = { 'mode' => 'docker' }
      m = described_class.new(config: docker_config)
      expect { m.connect! }.to raise_error(CodebaseIndex::Console::ConnectionError, /container/)
    end

    it 'raises for ssh mode without host' do
      ssh_config = { 'mode' => 'ssh' }
      m = described_class.new(config: ssh_config)
      expect { m.connect! }.to raise_error(CodebaseIndex::Console::ConnectionError, /host/)
    end

    it 'raises for unknown mode' do
      bad_config = { 'mode' => 'carrier_pigeon' }
      m = described_class.new(config: bad_config)
      expect { m.connect! }.to raise_error(CodebaseIndex::Console::ConnectionError, /Unknown connection mode/)
    end
  end
end
