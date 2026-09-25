# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/connection_manager'

RSpec.describe Woods::Console::ConnectionManager do
  describe '#command' do
    %w[connection console].each do |key|
      it "rejects unsupported #{key} nesting with migration guidance" do
        expect do
          described_class.new(config: { key => { 'mode' => 'ssh', 'host' => 'remote.example' } }).command
        end.to raise_error(Woods::Console::ConnectionError, /top-level.*mode.*Rails initializer/)
      end
    end

    %w[mod redacted_columns blocked_tables].each do |key|
      it "refuses ignored launcher configuration #{key}" do
        expect do
          described_class.new(config: { key => 'synthetic-configuration-value' }).command
        end.to raise_error(Woods::Console::ConnectionError) { |error|
          expect(error.message).to include(key)
          expect(error.message).not_to include('synthetic-configuration-value')
        }
      end
    end

    [{ 'mode' => 'ssh', 'host' => {} }, { 'command' => false }, { 'directory' => '' },
     { 'mode' => 'direct', 'container' => 'app' }].each do |config|
      it "rejects invalid launcher fields #{config.keys.join(', ')}" do
        expect { described_class.new(config: config).command }
          .to raise_error(Woods::Console::ConnectionError)
      end
    end

    it 'preserves direct mode for supported command and directory overrides' do
      manager = described_class.new(config: { 'command' => 'bin/rake woods:console', 'directory' => '/app' })
      expect(manager.command).to eq(%w[bin/rake woods:console])
    end

    it 'defaults to the embedded rake server when no app binstub exists' do
      manager = described_class.new(config: { 'directory' => '/missing-app-for-console-spec' })

      expect(manager.command).to eq(%w[bundle exec rake woods:console])
    end

    it 'prefers an executable app binstub without shell parsing its path' do
      Dir.mktmpdir('console app ') do |root|
        FileUtils.mkdir_p(File.join(root, 'bin'))
        binstub = File.join(root, 'bin/rake')
        File.write(binstub, "#!/usr/bin/env ruby\n")
        File.chmod(0o755, binstub)
        expect(described_class.new(config: { 'directory' => root }).command).to eq([binstub, 'woods:console'])
        File.chmod(0o644, binstub)
        expect(described_class.new(config: { 'directory' => root }).command)
          .to eq(%w[bundle exec rake woods:console])
      end
    end

    it 'keeps remote command selection independent of local binstubs' do
      expect(described_class.new(config: { 'mode' => 'docker', 'container' => 'app' }).command)
        .to eq(%w[docker exec -i app bundle exec rake woods:console])
      expect(described_class.new(config: { 'mode' => 'ssh', 'host' => 'app.example' }).command)
        .to eq(%w[ssh app.example bundle exec rake woods:console])
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
