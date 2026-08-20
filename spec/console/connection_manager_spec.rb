# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/connection_manager'

RSpec.describe Woods::Console::ConnectionManager do
  describe '#command' do
    it 'defaults to the embedded rake server in direct mode' do
      manager = described_class.new(config: {})

      expect(manager.command).to eq(%w[bundle exec rake woods:console])
    end

    it 'builds a direct command without invoking a shell' do
      manager = described_class.new(
        config: { 'mode' => 'direct', 'command' => 'bin/rake woods:console' }
      )

      expect(manager.command).to eq(%w[bin/rake woods:console])
    end

    it 'builds a docker exec command for the embedded server' do
      manager = described_class.new(
        config: { 'mode' => 'docker', 'container' => 'app', 'command' => 'bin/rake woods:console' }
      )

      expect(manager.command).to eq(%w[docker exec -i app bin/rake woods:console])
    end

    it 'builds an ssh command for the embedded server' do
      manager = described_class.new(
        config: { 'mode' => 'ssh', 'host' => 'example.test', 'user' => 'deploy',
                  'command' => 'bin/rake woods:console' }
      )

      expect(manager.command).to eq(%w[ssh deploy@example.test bin/rake woods:console])
    end

    it 'keeps shell metacharacters inside one argument' do
      manager = described_class.new(
        config: { 'mode' => 'docker', 'container' => 'app; touch /tmp/bad',
                  'command' => 'bin/rake woods:console' }
      )

      expect(manager.command).to eq(
        ['docker', 'exec', '-i', 'app; touch /tmp/bad', 'bin/rake', 'woods:console']
      )
    end

    it 'rejects an unknown mode' do
      manager = described_class.new(config: { 'mode' => 'unknown' })

      expect { manager.command }.to raise_error(Woods::Console::ConnectionError, /Unknown connection mode/)
    end

    it 'requires a container in docker mode' do
      manager = described_class.new(config: { 'mode' => 'docker' })

      expect { manager.command }.to raise_error(Woods::Console::ConnectionError, /container/)
    end

    it 'requires a host in ssh mode' do
      manager = described_class.new(config: { 'mode' => 'ssh' })

      expect { manager.command }.to raise_error(Woods::Console::ConnectionError, /host/)
    end
  end
end
