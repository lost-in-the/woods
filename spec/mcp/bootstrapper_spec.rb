# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/bootstrapper'

RSpec.describe Woods::MCP::Bootstrapper do
  describe '.resolve_index_dir' do
    let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

    context 'when argv supplies a valid directory containing manifest.json' do
      it 'returns the directory from argv[0]' do
        result = described_class.resolve_index_dir([fixture_dir])
        expect(result).to eq(fixture_dir)
      end
    end

    context 'when argv is empty and WOODS_DIR env var is set' do
      around do |example|
        old = ENV.delete('WOODS_DIR')
        ENV['WOODS_DIR'] = fixture_dir
        example.run
      ensure
        old ? ENV['WOODS_DIR'] = old : ENV.delete('WOODS_DIR')
      end

      it 'returns the directory from WOODS_DIR' do
        result = described_class.resolve_index_dir([])
        expect(result).to eq(fixture_dir)
      end
    end

    context 'resolution priority: argv[0] wins over WOODS_DIR' do
      around do |example|
        old = ENV.delete('WOODS_DIR')
        ENV['WOODS_DIR'] = fixture_dir
        example.run
      ensure
        old ? ENV['WOODS_DIR'] = old : ENV.delete('WOODS_DIR')
      end

      it 'uses argv[0] when both argv and WOODS_DIR are present' do
        result = described_class.resolve_index_dir([fixture_dir])
        expect(result).to eq(fixture_dir)
      end
    end

    context 'when the directory does not exist' do
      it 'exits with status 1' do
        expect do
          described_class.resolve_index_dir(['/definitely/not/a/real/woods/dir'])
        end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      it 'emits a descriptive error to stderr' do
        expect do
          described_class.resolve_index_dir(['/definitely/not/a/real/woods/dir'])
        end.to output(/Index directory does not exist/).to_stderr
           .and raise_error(SystemExit)
      end
    end

    context 'when the directory exists but lacks manifest.json' do
      it 'exits with status 1' do
        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_index_dir([dir])
          end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      it 'mentions manifest.json in the error output' do
        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_index_dir([dir])
          end.to output(/manifest\.json/).to_stderr
             .and raise_error(SystemExit)
        end
      end

      it 'suggests running woods:extract' do
        Dir.mktmpdir do |dir|
          expect do
            described_class.resolve_index_dir([dir])
          end.to output(/woods:extract/).to_stderr
             .and raise_error(SystemExit)
        end
      end
    end

    context 'when argv is empty and WOODS_DIR is unset (Dir.pwd fallback)' do
      around do |example|
        old = ENV.delete('WOODS_DIR')
        example.run
      ensure
        old ? ENV['WOODS_DIR'] = old : ENV.delete('WOODS_DIR')
      end

      it 'exits when Dir.pwd has no manifest.json' do
        # Gem root never has a manifest.json — safe to assume SystemExit here
        unless File.exist?(File.join(Dir.pwd, 'manifest.json'))
          expect do
            described_class.resolve_index_dir([])
          end.to raise_error(SystemExit)
        end
      end
    end
  end

  describe '.build_snapshot_store' do
    context 'when snapshots are disabled (no env var, no SQLite DB, config off)' do
      around do |example|
        old = ENV.delete('WOODS_SNAPSHOTS')
        example.run
      ensure
        old ? ENV['WOODS_SNAPSHOTS'] = old : ENV.delete('WOODS_SNAPSHOTS')
      end

      it 'returns nil' do
        Dir.mktmpdir do |dir|
          allow(Woods.configuration).to receive(:enable_snapshots).and_return(false)
          result = described_class.build_snapshot_store(dir)
          expect(result).to be_nil
        end
      end
    end

    context 'when WOODS_SNAPSHOTS=true' do
      around do |example|
        old = ENV.delete('WOODS_SNAPSHOTS')
        ENV['WOODS_SNAPSHOTS'] = 'true'
        example.run
      ensure
        old ? ENV['WOODS_SNAPSHOTS'] = old : ENV.delete('WOODS_SNAPSHOTS')
      end

      it 'returns a snapshot store object rather than nil' do
        Dir.mktmpdir do |dir|
          result = described_class.build_snapshot_store(dir)
          expect(result).not_to be_nil
        end
      end
    end

    context 'when a woods.sqlite3 file already exists in the index directory' do
      around do |example|
        old = ENV.delete('WOODS_SNAPSHOTS')
        example.run
      ensure
        old ? ENV['WOODS_SNAPSHOTS'] = old : ENV.delete('WOODS_SNAPSHOTS')
      end

      it 'auto-enables and returns a store' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'woods.sqlite3'))
          allow(Woods.configuration).to receive(:enable_snapshots).and_return(false)
          result = described_class.build_snapshot_store(dir)
          expect(result).not_to be_nil
        end
      end
    end
  end

  describe '.ollama_reachable?' do
    it 'returns false when nothing is listening on the configured port' do
      old = ENV.delete('OLLAMA_BASE_URL')
      ENV['OLLAMA_BASE_URL'] = 'http://127.0.0.1:19999'
      result = described_class.ollama_reachable?
      expect(result).to be false
    ensure
      old ? ENV['OLLAMA_BASE_URL'] = old : ENV.delete('OLLAMA_BASE_URL')
    end

    it 'returns false given a non-parseable URL (rescue StandardError path)' do
      old = ENV.delete('OLLAMA_BASE_URL')
      ENV['OLLAMA_BASE_URL'] = 'not_a_url'
      result = described_class.ollama_reachable?
      expect(result).to be false
    ensure
      old ? ENV['OLLAMA_BASE_URL'] = old : ENV.delete('OLLAMA_BASE_URL')
    end
  end

  describe '.build_retriever' do
    # The decomposed build_retriever returns [retriever, BootstrapState].
    # It refuses to silently auto-detect anymore — no woods.json + no
    # explicit opt-in raises MissingArtifact. Callers rescue the typed
    # error at the top level (see exe/woods-mcp).
    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    context 'when no woods.json exists and autodetect is not opted in' do
      it 'raises Woods::MCP::MissingArtifact with an actionable message' do
        Dir.mktmpdir do |dir|
          expect { described_class.build_retriever(index_dir: dir) }
            .to raise_error(Woods::MCP::MissingArtifact, /WOODS_ALLOW_AUTODETECT/)
        end
      end
    end

    context 'when no woods.json exists and WOODS_ALLOW_AUTODETECT=1 is set' do
      it 'falls through to env-var auto-detect (deprecated path)' do
        ENV['WOODS_ALLOW_AUTODETECT'] = '1'
        ENV.delete('OPENAI_API_KEY')
        # Stub the Ollama reachability check — the machine running the
        # spec might have Ollama listening on localhost, which would
        # otherwise cause autodetect to succeed and defeat the test.
        allow(described_class).to receive(:ollama_reachable?).and_return(false)

        Dir.mktmpdir do |dir|
          # No credentials, no Ollama — auto-detect finds nothing and
          # returns a nil retriever instead of raising. The caller
          # diagnoses via BootstrapState.
          retriever, state = described_class.build_retriever(index_dir: dir)
          expect(retriever).to be_nil
          expect(state).to be_a(Woods::MCP::BootstrapState)
        end
      ensure
        ENV.delete('WOODS_ALLOW_AUTODETECT')
      end
    end

    context 'when the host initializer already set an embedding_provider' do
      it 'skips autodetect and trusts the host config' do
        Woods.configuration.vector_store = :in_memory
        Woods.configuration.metadata_store = :in_memory
        Woods.configuration.graph_store = :in_memory
        Woods.configuration.embedding_provider = :ollama
        Woods.configuration.embedding_options = {
          host: 'http://127.0.0.1:19999',
          model: 'nomic-embed-text'
        }

        Dir.mktmpdir do |dir|
          # Provider is unreachable (nothing on :19999) → starts degraded
          # rather than raising. Retriever comes back non-nil.
          retriever, state = described_class.build_retriever(index_dir: dir)
          expect(retriever).not_to be_nil
          expect(state.status).to eq(:degraded)
          expect(state.reason).to be_a(Woods::MCP::ProviderUnreachable)
        end
      end
    end
  end
end
