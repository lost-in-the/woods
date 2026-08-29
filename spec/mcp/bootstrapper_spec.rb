# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/server'

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

    context 'when the directory has a payload-born index (#164 payloads)' do
      it 'resolves through the generation pointer when the root has no manifest.json' do
        Dir.mktmpdir do |dir|
          payload_dir = File.join(dir, 'payloads', 'gen-1')
          FileUtils.mkdir_p(payload_dir)
          FileUtils.touch(File.join(payload_dir, 'manifest.json'))
          File.write(File.join(dir, 'generation.json'),
                     JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))

          result = described_class.resolve_index_dir([dir])
          expect(result).to eq(dir)
        end
      end

      it 'still rejects a directory with neither a root manifest nor a resolvable payload manifest' do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, 'generation.json'),
                     JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))

          expect do
            described_class.resolve_index_dir([dir])
          end.to output(/No manifest\.json found in/).to_stderr
             .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
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
    # Extract-only hosts (no woods.json + no provider) boot in pattern/
    # structural mode by default — auto-detect runs and returns a nil
    # retriever when no credentials are present (#138). Strict deployments
    # set WOODS_REQUIRE_INDEX=1 to fail closed with MissingArtifact, which
    # callers rescue at the top level (see exe/woods-mcp).
    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      ENV.delete('WOODS_REQUIRE_INDEX')
      example.run
    ensure
      Woods.configuration = original
    end

    context 'when no woods.json exists and no provider is configured (extract-only)' do
      it 'boots in pattern-only mode with a nil retriever instead of raising (#138)' do
        ENV.delete('OPENAI_API_KEY')
        # Stub the Ollama reachability check — the machine running the
        # spec might have Ollama listening on localhost, which would
        # otherwise cause autodetect to wire a provider and defeat the test.
        allow(described_class).to receive(:ollama_reachable?).and_return(false)

        Dir.mktmpdir do |dir|
          retriever, state = described_class.build_retriever(index_dir: dir)
          expect(retriever).to be_nil
          expect(state).to be_a(Woods::MCP::BootstrapState)
        end
      end
    end

    context 'when no woods.json exists and WOODS_REQUIRE_INDEX=1 is set (strict)' do
      it 'raises Woods::MCP::MissingArtifact with an actionable message' do
        ENV['WOODS_REQUIRE_INDEX'] = '1'
        allow(described_class).to receive(:ollama_reachable?).and_return(false)

        Dir.mktmpdir do |dir|
          expect { described_class.build_retriever(index_dir: dir) }
            .to raise_error(Woods::MCP::MissingArtifact, /WOODS_REQUIRE_INDEX/)
        end
      ensure
        ENV.delete('WOODS_REQUIRE_INDEX')
      end
    end

    context 'when no woods.json exists and legacy WOODS_ALLOW_AUTODETECT=1 is set' do
      it 'still boots via auto-detect (back-compat no-op)' do
        ENV['WOODS_ALLOW_AUTODETECT'] = '1'
        ENV.delete('OPENAI_API_KEY')
        allow(described_class).to receive(:ollama_reachable?).and_return(false)

        Dir.mktmpdir do |dir|
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

    context 'when a Snapshotter dump exists in output_dir' do
      # Shape-2 payoff: a previous embed wrote vectors + metadata via
      # the Snapshotter; the Bootstrapper hydrates in-memory stores from
      # those dumps at boot. Without this wiring, admin would embed,
      # restart MCP, and still see empty stores.
      it 'hydrates the retriever from the latest dump' do
        require 'woods/resolved_config'
        require 'woods/index_artifact'
        require 'woods/storage/snapshotter'

        Woods.configuration.vector_store = :in_memory
        Woods.configuration.metadata_store = :in_memory
        Woods.configuration.graph_store = :in_memory
        Woods.configuration.embedding_provider = :ollama
        Woods.configuration.embedding_options = {
          host: 'http://127.0.0.1:19999',
          model: 'nomic-embed-text',
          dimension: 4
        }

        Dir.mktmpdir do |dir|
          # Simulate what the Indexer does at end-of-embed.
          source_vs = Woods::Storage::VectorStore::InMemory.new
          source_vs.store('Foo', [0.5, 0.5, 0.5, 0.5], { 'type' => 'model' })
          source_vs.store('Bar', [0.1, 0.2, 0.3, 0.4], { 'type' => 'service' })

          source_ms = Woods::Storage::MetadataStore::InMemory.new
          source_ms.store('Foo', { 'type' => 'model' })
          source_ms.store('Bar', { 'type' => 'service' })

          artifact = Woods::IndexArtifact.new(dir)
          resolved = Woods::ResolvedConfig.from_configuration(Woods.configuration)
          dump_dir = artifact.new_dump_dir

          Woods::Storage::Snapshotter::Vector.dump(source_vs, artifact, dump_dir, resolved_config: resolved)
          Woods::Storage::Snapshotter::Metadata.dump(source_ms, artifact, dump_dir, resolved_config: resolved)
          artifact.write_config(resolved.to_snapshot_json)
          artifact.promote(dump_dir)

          retriever, _state = described_class.build_retriever(index_dir: dir)
          expect(retriever).not_to be_nil

          # Retriever doesn't expose vector_store publicly. Fetch via
          # the SearchExecutor it composes — if the Bootstrapper fed a
          # hydrated store through, it lives here. This is the key
          # assertion: dumps on disk → retriever sees them.
          executor = retriever.instance_variable_get(:@executor)
          vs = executor.instance_variable_get(:@vector_store)
          ms = retriever.instance_variable_get(:@metadata_store)

          expect(vs.count).to eq(2)
          expect(ms.count).to eq(2)
          expect(vs.each_entry.map { |id, _, _| id }).to contain_exactly('Foo', 'Bar')
        end
      end
    end
  end

  describe 'failure-mode: hydration soft-failures' do
    # hydrated_vector_store and hydrated_metadata_store rescue non-BootstrapError
    # StandardErrors with a warn, returning nil so Builder constructs an empty store.
    # BootstrapError and ArgumentError are NOT swallowed — they propagate.

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    before do
      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }
    end

    it 'returns a non-nil retriever when vector hydration raises a transient StandardError' do
      Dir.mktmpdir do |dir|
        allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty).and_raise(
          RuntimeError, 'simulated I/O error'
        )
        expect do
          retriever, = described_class.build_retriever(index_dir: dir)
          expect(retriever).not_to be_nil
        end.to output(/vector hydration failed/).to_stderr
      end
    end

    it 'returns a non-nil retriever when metadata hydration raises a transient StandardError' do
      Dir.mktmpdir do |dir|
        allow(Woods::Storage::Snapshotter::Metadata).to receive(:load_or_empty).and_raise(
          RuntimeError, 'simulated I/O error'
        )
        expect do
          retriever, = described_class.build_retriever(index_dir: dir)
          expect(retriever).not_to be_nil
        end.to output(/metadata hydration failed/).to_stderr
      end
    end

    it 'propagates BootstrapError from vector hydration (not swallowed)' do
      Dir.mktmpdir do |dir|
        allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty).and_raise(
          Woods::MCP::UnsupportedArtifact, 'schema version too new'
        )
        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::MCP::UnsupportedArtifact)
      end
    end

    it 'propagates ArgumentError from vector hydration (not swallowed)' do
      Dir.mktmpdir do |dir|
        allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty).and_raise(
          ArgumentError, 'dump_dir outside dumps_root'
        )
        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(ArgumentError)
      end
    end
  end

  describe 'M6: hydration failure must not report :hydrated' do
    # A hydration soft-failure used to leave empty stores behind only a
    # stderr warning while probe_and_mark_state marked :hydrated on provider
    # reachability alone: a "healthy" server that answers everything with
    # nothing. The state must be derived from store health, and
    # codebase_retrieve must return typed degraded metadata instead of a
    # clean empty result.
    let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    before do
      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }
      # Isolate the hydration signal: the provider is fine, the store is not.
      allow(Woods::MCP::ProviderProbe).to receive(:reachable!).and_return(true)
    end

    it 'marks :degraded with the hydration error when metadata hydration fails' do
      allow(Woods::Storage::Snapshotter::Metadata).to receive(:load_or_empty).and_raise(
        RuntimeError, 'simulated I/O error'
      )
      Dir.mktmpdir do |dir|
        retriever, state = nil
        expect do
          retriever, state = described_class.build_retriever(index_dir: dir)
        end.to output(/metadata hydration failed/).to_stderr

        expect(retriever).not_to be_nil
        expect(state.status).to eq(:degraded)
        expect(state.status).not_to eq(:hydrated)
        expect(state.hydration_failed?).to be(true)
        expect(state.reason.message).to include('simulated I/O error')
      end
    end

    it 'marks :degraded with the hydration error when vector hydration fails' do
      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty).and_raise(
        RuntimeError, 'simulated dump corruption'
      )
      Dir.mktmpdir do |dir|
        retriever, state = described_class.build_retriever(index_dir: dir)

        expect(retriever).not_to be_nil
        expect(state.status).to eq(:degraded)
        expect(state.hydration_failed?).to be(true)
        expect(state.reason.message).to include('simulated dump corruption')
      end
    end

    it 'keeps :hydrated when every store hydrates cleanly' do
      Dir.mktmpdir do |dir|
        _retriever, state = described_class.build_retriever(index_dir: dir)

        expect(state.status).to eq(:hydrated)
        expect(state.hydration_failed?).to be(false)
      end
    end

    it 'surfaces typed degraded metadata through codebase_retrieve instead of a clean empty result' do
      allow(Woods::Storage::Snapshotter::Metadata).to receive(:load_or_empty).and_raise(
        RuntimeError, 'simulated I/O error'
      )
      retriever, state = described_class.build_retriever(index_dir: fixture_dir)
      server = Woods::MCP::Server.build(
        index_dir: fixture_dir, retriever: retriever, bootstrap_state: state, response_format: :json
      )

      tools = server.instance_variable_get(:@tools)
      response = tools['codebase_retrieve'].call(query: 'How does authentication work?', server_context: {})

      expect(response.error?).to be(true)
      expect(response.meta[:error_code]).to eq(:degraded_index)
      expect(response.meta[:degraded]).to be(true)
      expect(response.content.first[:text]).to include('degraded')
    end
  end

  describe 'failure-mode: config-invalid errors from ConfigResolver' do
    # ConfigResolver raises typed BootstrapError subclasses for config-shape
    # problems. build_retriever must not swallow them.

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    it 'raises the typed Woods::ConfigurationError when the host provider is unusable (M9)' do
      # A host initializer that sets :openai without a usable api_key cannot
      # be auto-resolved. The raise is typed so the top-level rescue in
      # exe/woods-mcp (BootstrapError, ConfigurationError) prints the
      # one-line operator message instead of a raw backtrace.
      Woods.configuration.embedding_provider = :openai
      Woods.configuration.embedding_options = { api_key: '' }

      Dir.mktmpdir do |dir|
        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::ConfigurationError, /api_key/)
      end
    end

    it 'propagates UnsupportedArtifact when woods.json has a future schema_version' do
      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        future_config = {
          'schema_version' => 999,
          'gem_version' => '99.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(future_config)

        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::MCP::UnsupportedArtifact, /schema_version 999/)
      end
    end

    it 'propagates DimensionMismatch when live provider dimension differs from woods.json' do
      require 'woods/index_artifact'
      require 'woods/resolved_config'

      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 768
      }

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        # woods.json says 384 dimensions; live config says 768 — mismatch
        stored_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 384
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(stored_config)

        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::MCP::DimensionMismatch)
      end
    end

    it 'propagates MissingCredential when woods.json says OpenAI but OPENAI_API_KEY is unset' do
      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        openai_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::OpenAI',
            'model' => 'text-embedding-3-small',
            'dimension' => 1536
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(openai_config)

        old_key = ENV.delete('OPENAI_API_KEY')
        begin
          expect { described_class.build_retriever(index_dir: dir) }
            .to raise_error(Woods::MCP::MissingCredential, /OPENAI_API_KEY/)
        ensure
          ENV['OPENAI_API_KEY'] = old_key if old_key
        end
      end
    end

    it 'propagates ConfigMismatch when live provider class differs from woods.json' do
      require 'woods/index_artifact'

      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 768
      }

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        # woods.json says OpenAI; live config says Ollama — class mismatch
        stored_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::OpenAI',
            'model' => 'text-embedding-3-small',
            'dimension' => 768
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(stored_config)

        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::MCP::ConfigMismatch)
      end
    end

    it 'rejects woods.json with schema_version=0 (version.positive? guard)' do
      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        zero_version_config = {
          'schema_version' => 0,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(zero_version_config)

        expect { described_class.build_retriever(index_dir: dir) }
          .to raise_error(Woods::MCP::UnsupportedArtifact, /schema_version 0/)
      end
    end

    it 'accepts woods.json with schema_version=1 without raising' do
      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        valid_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4,
            'host' => 'http://127.0.0.1:19999'
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(valid_config)

        # Ollama unreachable → starts degraded but does not raise
        expect { described_class.build_retriever(index_dir: dir) }
          .not_to raise_error
      end
    end
  end

  describe 'failure-mode: populate_vector_metadata edge cases' do
    # populate_vector_metadata back-fills metadata into vector store entries
    # after a dump/reload cycle. These specs exercise the two gap cases that
    # can arise: empty metadata store and ids present in vectors but not in metadata.

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    before do
      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }
    end

    def write_artifact(dir, vector_entries:, metadata_entries:)
      require 'woods/resolved_config'
      require 'woods/index_artifact'
      require 'woods/storage/snapshotter'

      source_vs = Woods::Storage::VectorStore::InMemory.new
      vector_entries.each { |id, vec, meta| source_vs.store(id, vec, meta || {}) }

      source_ms = Woods::Storage::MetadataStore::InMemory.new
      metadata_entries.each { |id, meta| source_ms.store(id, meta) }

      artifact = Woods::IndexArtifact.new(dir)
      resolved = Woods::ResolvedConfig.from_configuration(Woods.configuration)
      dump_dir = artifact.new_dump_dir

      Woods::Storage::Snapshotter::Vector.dump(source_vs, artifact, dump_dir, resolved_config: resolved)
      Woods::Storage::Snapshotter::Metadata.dump(source_ms, artifact, dump_dir, resolved_config: resolved)
      artifact.write_config(resolved.to_snapshot_json)
      artifact.promote(dump_dir)
    end

    it 'vector entries survive with empty metadata hashes when metadata store is empty' do
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [
            ['A', [1.0, 0.0, 0.0, 0.0], {}],
            ['B', [0.0, 1.0, 0.0, 0.0], {}],
            ['C', [0.0, 0.0, 1.0, 0.0], {}],
            ['D', [0.0, 0.0, 0.0, 1.0], {}],
            ['E', [0.7, 0.7, 0.0, 0.0], {}]
          ],
          metadata_entries: [] # empty metadata store
        )

        retriever, = described_class.build_retriever(index_dir: dir)
        expect(retriever).not_to be_nil

        executor = retriever.instance_variable_get(:@executor)
        vs = executor.instance_variable_get(:@vector_store)
        expect(vs.count).to eq(5)
      end
    end

    it 'back-fills chunked vector entries from base-identifier metadata' do
      # The Indexer keys per-chunk vector rows as +Foo#chunk_N+ but stores
      # unit metadata under the base identifier +Foo+ only. Without
      # stripping the chunk suffix, the hydration lookup misses and
      # chunked entries never get their type/file_path/identifier metadata
      # rebuilt — which then forces the retrieval path into its fallback
      # and re-introduces the same key-mismatch bug at that layer.
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [
            ['User#chunk_0', [1.0, 0.0, 0.0, 0.0], {}],
            ['User#chunk_1', [0.0, 1.0, 0.0, 0.0], {}],
            ['Post',         [0.0, 0.0, 1.0, 0.0], {}]
          ],
          metadata_entries: [
            ['User', { 'type' => 'model', 'file_path' => 'app/models/user.rb' }],
            ['Post', { 'type' => 'model', 'file_path' => 'app/models/post.rb' }]
          ]
        )

        retriever, = described_class.build_retriever(index_dir: dir)
        executor = retriever.instance_variable_get(:@executor)
        vs = executor.instance_variable_get(:@vector_store)

        # The back-fill writes the SYMBOL-keyed filter subset the Indexer's
        # live embed path writes ({ type:, identifier:, file_path: }) — not
        # the raw string-keyed metadata record. See #150 item 5: the
        # InMemory vector store probes meta[:type] for filter predicates.
        metadata_by_id = vs.each_entry.to_h { |id, _, meta| [id, meta] }
        expect(metadata_by_id['User#chunk_0']).to include(type: 'model',
                                                          file_path: 'app/models/user.rb')
        expect(metadata_by_id['User#chunk_1']).to include(type: 'model',
                                                          file_path: 'app/models/user.rb')
        expect(metadata_by_id['Post']).to include(type: 'model',
                                                  file_path: 'app/models/post.rb')
      end
    end

    # Regression — #150 item 5. Dump-hydrated vector metadata was back-filled
    # as the metadata store's raw STRING-keyed record, but
    # SearchExecutor#build_vector_filters builds SYMBOL-keyed filters and
    # VectorStore::InMemory#gather_candidates probes meta[:type] directly —
    # so every type-filtered codebase_retrieve returned EMPTY on a booted
    # server. The live embed path (Indexer#store_vectors) writes symbol keys,
    # which is why in-process specs never saw it.
    it 'back-fills symbol-keyed metadata so a type-filtered vector search finds the unit' do
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [
            ['User', [1.0, 0.0, 0.0, 0.0], {}],
            ['PaymentsService', [0.0, 1.0, 0.0, 0.0], {}]
          ],
          metadata_entries: [
            ['User', { 'type' => 'model', 'identifier' => 'User',
                       'file_path' => 'app/models/user.rb' }],
            ['PaymentsService', { 'type' => 'service', 'identifier' => 'PaymentsService',
                                  'file_path' => 'app/services/payments_service.rb' }]
          ]
        )

        retriever, = described_class.build_retriever(index_dir: dir)
        results = retriever.vector_store.search([1.0, 0.0, 0.0, 0.0], limit: 5,
                                                                      filters: { type: %w[model] })

        expect(results.map(&:id)).to eq(%w[User])
      end
    end

    it 're-runs the back-fill on reload so type-filtered search still works (reload path of #150)' do
      # reload_stores! bulk-loads vectors from the WVF1 dump, which carries
      # NO per-vector metadata — without a post-refill back-fill, a reload
      # wiped the filter metadata the boot path had populated and every
      # type-filtered search went empty until process restart.
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [['User', [1.0, 0.0, 0.0, 0.0], {}]],
          metadata_entries: [
            ['User', { 'type' => 'model', 'identifier' => 'User',
                       'file_path' => 'app/models/user.rb' }]
          ]
        )

        retriever, = described_class.build_retriever(index_dir: dir)
        described_class.reload_stores!(retriever, index_dir: dir)

        results = retriever.vector_store.search([1.0, 0.0, 0.0, 0.0], limit: 5,
                                                                      filters: { type: %w[model] })
        expect(results.map(&:id)).to eq(%w[User])
      end
    end

    it 'invalidates the Ranker pagerank memo on reload (stale PageRank after replace_graph)' do
      # reload_stores! swaps the graph inside the shared GraphStore wrapper
      # via replace_graph; the Ranker's rank-percentile map is memoized from
      # the OLD graph and must be dropped alongside the context cache.
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [['User', [1.0, 0.0, 0.0, 0.0], {}]],
          metadata_entries: [['User', { 'type' => 'model' }]]
        )

        retriever, = described_class.build_retriever(index_dir: dir)
        ranker = retriever.instance_variable_get(:@ranker)
        expect(ranker).to be_a(Woods::Retrieval::Ranker)

        allow(ranker).to receive(:invalidate_pagerank_cache!).and_call_original
        described_class.reload_stores!(retriever, index_dir: dir)

        expect(ranker).to have_received(:invalidate_pagerank_cache!)
      end
    end

    it 'ids in vector store but absent from metadata store keep empty metadata hash (no raise)' do
      Dir.mktmpdir do |dir|
        write_artifact(
          dir,
          vector_entries: [
            ['A', [1.0, 0.0, 0.0, 0.0], {}],
            ['B', [0.0, 1.0, 0.0, 0.0], {}],
            ['D', [0.0, 0.0, 0.0, 1.0], {}] # D has no metadata entry
          ],
          metadata_entries: [
            ['A', { 'type' => 'model' }],
            ['B', { 'type' => 'service' }],
            ['C', { 'type' => 'controller' }] # C has metadata but no vector
          ]
        )

        expect { described_class.build_retriever(index_dir: dir) }.not_to raise_error

        retriever, = described_class.build_retriever(index_dir: dir)
        executor = retriever.instance_variable_get(:@executor)
        vs = executor.instance_variable_get(:@vector_store)

        # All 3 vector entries survive
        expect(vs.count).to eq(3)
        # A and B got their metadata back-filled; D keeps empty hash
        ids = vs.each_entry.map { |id, _, _| id }
        expect(ids).to contain_exactly('A', 'B', 'D')
      end
    end
  end

  describe 'failure-mode: reload backfill must not raise on durable vector stores (B-108)' do
    # populate_reloaded_vector_metadata reaches whatever vector_store the
    # retriever holds LIVE -- including a durable adapter, when the reload
    # tool runs against a pgvector/Qdrant configuration. Before the fix the
    # guard was `respond_to?(:each_entry)`, which every adapter answers true
    # for because Storage::VectorStore::Interface DEFINES each_entry as a
    # raising stub -- so this crashed the stdio server the first time
    # `reload` ran against a durable backend (NotImplementedError is a
    # ScriptError; it unwinds straight through `rescue StandardError`).
    let(:durable_vector_store_class) do
      Class.new do
        include Woods::Storage::VectorStore::Interface

        def each_id
          [].each
        end

        def store(id, _vector, _metadata = {})
          id
        end
      end
    end

    it 'skips the metadata back-fill instead of calling the raising each_entry stub' do
      durable_vs = durable_vector_store_class.new
      metadata_store = instance_double(Woods::Storage::MetadataStore::InMemory, find: {})

      expect do
        described_class.send(:populate_vector_metadata, durable_vs, metadata_store)
      end.not_to raise_error
    end

    it 'is reachable via populate_reloaded_vector_metadata on a retriever holding a durable store' do
      durable_vs = durable_vector_store_class.new
      retriever = instance_double(
        Woods::Retriever,
        vector_store: durable_vs,
        metadata_store: instance_double(Woods::Storage::MetadataStore::InMemory, find: {})
      )

      expect do
        described_class.send(:populate_reloaded_vector_metadata, retriever)
      end.not_to raise_error
    end
  end

  describe 'failure-mode: durable backends bypass Snapshotter' do
    # When config.vector_store is not :in_memory (e.g. :pgvector), the
    # hydrated_vector_store helper returns nil early. Snapshotter::Vector.load_or_empty
    # must never be called — durable backends are already persistent.

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    it 'does not call Snapshotter::Vector.load_or_empty when vector_store is :pgvector' do
      require 'woods/index_artifact'

      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        # Write a valid woods.json so ConfigResolver doesn't raise MissingArtifact
        valid_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4,
            'host' => 'http://127.0.0.1:19999'
          },
          'stores' => { 'vector_store' => 'pgvector',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(valid_config)

        expect(Woods::Storage::Snapshotter::Vector).not_to receive(:load_or_empty)

        # pgvector construction will likely fail — rescue any error that isn't
        # about Snapshotter being called (we only care about the negative assertion)
        described_class.build_retriever(index_dir: dir) rescue nil # rubocop:disable Style/RescueModifier
      end
    end
  end

  describe 'scenario: woods.json present + matching host config uses :snapshot source' do
    # ConfigResolver.resolve returns [:snapshot, config] when woods.json is present,
    # regardless of whether the host has a provider configured. When the host config
    # matches, no ConfigMismatch is raised and the source tag is :snapshot.
    # This spec exercises the happy path through apply_stored_config.

    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      ENV.delete('WOODS_ALLOW_AUTODETECT')
      example.run
    ensure
      Woods.configuration = original
    end

    it 'succeeds and does not mutate the config object identity' do
      require 'woods/index_artifact'
      require 'woods/mcp/config_resolver'

      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        # woods.json that exactly matches the live host config
        matching_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4,
            'host' => 'http://127.0.0.1:19999'
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(matching_config)

        config_before = Woods.configuration
        # Degrade gracefully — provider unreachable is fine for this test
        described_class.build_retriever(index_dir: dir) rescue nil # rubocop:disable Style/RescueModifier

        # Config identity must not change: build_retriever must not replace
        # Woods.configuration with a new object
        expect(Woods.configuration).to equal(config_before)
      end
    end

    it 'resolves to :snapshot source when woods.json matches host config' do
      require 'woods/index_artifact'
      require 'woods/mcp/config_resolver'

      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        host: 'http://127.0.0.1:19999',
        model: 'nomic-embed-text',
        dimension: 4
      }

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        matching_config = {
          'schema_version' => 1,
          'gem_version' => '1.0.0',
          'created_at' => '2026-01-01T00:00:00Z',
          'embedding_provider' => {
            'class' => 'Woods::Embedding::Provider::Ollama',
            'model' => 'nomic-embed-text',
            'dimension' => 4,
            'host' => 'http://127.0.0.1:19999'
          },
          'stores' => { 'vector_store' => 'in_memory',
                        'metadata_store' => 'in_memory',
                        'graph_store' => 'in_memory' }
        }
        artifact.write_config(matching_config)

        _resolved, source = Woods::MCP::ConfigResolver.resolve(
          Woods.configuration,
          artifact: artifact
        )
        expect(source).to eq(:snapshot)
      end
    end
  end

  # Regression — the Indexer accepted a graph_store kwarg and dumped it
  # empty at end of run, but never populated it. Retrieval's :hybrid
  # strategy called @graph_store.dependencies_of on the empty store and
  # got [] back, silently dropping the graph-expansion step. The fix
  # hydrates the retriever's graph_store from dependency_graph.json on
  # disk, which extraction has always written with the real graph.
  describe 'graph store hydration' do
    around do |example|
      original = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      example.run
    ensure
      Woods.configuration = original
    end

    it 'returns a populated GraphStore::Memory when dependency_graph.json exists' do
      require 'woods/index_artifact'
      require 'woods/storage/graph_store'

      Woods.configuration.graph_store = :in_memory

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        graph_data = {
          'nodes' => {
            'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb', 'namespace' => nil },
            'Organization' => { 'type' => 'model', 'file_path' => 'app/models/organization.rb', 'namespace' => nil }
          },
          'edges' => { 'User' => [{ 'target' => 'Organization', 'via' => 'belongs_to' }] },
          'reverse' => { 'Organization' => ['User'] },
          'type_index' => { 'model' => %w[User Organization] }
        }
        File.write(File.join(dir, 'dependency_graph.json'), JSON.generate(graph_data))

        store = described_class.send(:hydrated_graph_store, Woods.configuration, artifact)

        expect(store).to be_a(Woods::Storage::GraphStore::Memory)
        expect(store.dependencies_of('User')).to include('Organization')
        expect(store.dependents_of('Organization')).to include('User')
      end
    end

    it 'hydrates from a payload directory when dependency_graph.json lives only there (#164 payloads)' do
      require 'woods/index_artifact'
      require 'woods/storage/graph_store'

      Woods.configuration.graph_store = :in_memory

      Dir.mktmpdir do |dir|
        payload_dir = File.join(dir, 'payloads', 'gen-1')
        FileUtils.mkdir_p(payload_dir)
        graph_data = {
          'nodes' => {
            'User' => { 'type' => 'model', 'file_path' => 'app/models/user.rb', 'namespace' => nil },
            'Organization' => { 'type' => 'model', 'file_path' => 'app/models/organization.rb', 'namespace' => nil }
          },
          'edges' => { 'User' => [{ 'target' => 'Organization', 'via' => 'belongs_to' }] },
          'reverse' => { 'Organization' => ['User'] },
          'type_index' => { 'model' => %w[User Organization] }
        }
        File.write(File.join(payload_dir, 'dependency_graph.json'), JSON.generate(graph_data))
        File.write(File.join(dir, 'generation.json'),
                   JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))

        artifact = Woods::IndexArtifact.new(dir)
        store = described_class.send(:hydrated_graph_store, Woods.configuration, artifact)

        expect(store).to be_a(Woods::Storage::GraphStore::Memory)
        expect(store.dependencies_of('User')).to include('Organization')
        expect(store.dependents_of('Organization')).to include('User')
      end
    end

    it 'returns nil when dependency_graph.json is missing' do
      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        store = described_class.send(:hydrated_graph_store, Woods.configuration, artifact)
        expect(store).to be_nil
      end
    end

    it 'raises InapplicableBackend when the configured graph_store reports durable? => true' do
      # Build a real interface-conforming stand-in for a durable adapter.
      # Testing against a plain symbol / instance_double would let a future
      # MySQL-backed graph adapter slip past the guard with a mis-shaped
      # interface — this asserts the guard fires on the real capability check.
      durable_adapter_class = Class.new do
        include Woods::Storage::GraphStore::Interface

        def durable? = true
        def dependencies_of(_identifier) = []
        def dependents_of(_identifier) = []
        def affected_by(_changed_files, max_depth: nil) = [] # rubocop:disable Lint/UnusedMethodArgument
        def by_type(_type) = []
        def pagerank(damping: 0.85, iterations: 20) = {} # rubocop:disable Lint/UnusedMethodArgument
      end
      durable_store = durable_adapter_class.new

      builder_double = instance_double(Woods::Builder, build_graph_store: durable_store)
      allow(Woods::Builder).to receive(:new).and_return(builder_double)

      require 'woods/index_artifact'

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        File.write(File.join(dir, 'dependency_graph.json'), JSON.generate('nodes' => {}, 'edges' => {}))

        expect do
          described_class.send(:hydrated_graph_store, Woods.configuration, artifact)
        end.to raise_error(Woods::Storage::InapplicableBackend, /durable/)
      end
    end

    it 'returns nil and warns when dependency_graph.json is malformed' do
      require 'woods/index_artifact'

      Woods.configuration.graph_store = :in_memory

      Dir.mktmpdir do |dir|
        artifact = Woods::IndexArtifact.new(dir)
        File.write(File.join(dir, 'dependency_graph.json'), 'not valid json')

        expect do
          store = described_class.send(:hydrated_graph_store, Woods.configuration, artifact)
          expect(store).to be_nil
        end.to output(/graph hydration failed/).to_stderr
      end
    end
  end
end
