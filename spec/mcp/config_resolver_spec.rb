# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/index_artifact'
require 'woods/resolved_config'
require 'woods/mcp/errors'
require 'woods/mcp/config_resolver'

RSpec.describe Woods::MCP::ConfigResolver do
  let(:blank_config) do
    cfg = Woods::Configuration.new
    cfg.vector_store = nil
    cfg.metadata_store = nil
    cfg.graph_store = nil
    cfg.embedding_provider = nil
    cfg.embedding_options = nil
    cfg
  end

  let(:ollama_config) do
    cfg = Woods::Configuration.new
    cfg.vector_store = :in_memory
    cfg.metadata_store = :in_memory
    cfg.graph_store = :in_memory
    cfg.embedding_provider = :ollama
    cfg.embedding_options = { host: 'http://localhost:11434', model: 'nomic-embed-text', dimension: 768 }
    cfg
  end

  # Minimal valid woods.json payload for a 768-dim Ollama provider
  let(:woods_json_hash) do
    {
      'schema_version' => 1,
      'gem_version' => '1.0.0',
      'created_at' => '2026-04-20T00:00:00Z',
      'embedding_provider' => {
        'class' => 'Woods::Embedding::Provider::Ollama',
        'model' => 'nomic-embed-text',
        'host' => 'http://localhost:11434',
        'dimension' => 768
      },
      'stores' => {
        'vector_store' => 'in_memory',
        'metadata_store' => 'in_memory',
        'graph_store' => 'in_memory'
      }
    }
  end

  def write_woods_json(dir, content = woods_json_hash)
    File.write(File.join(dir, 'woods.json'), JSON.generate(content))
  end

  describe '.resolve' do
    context 'woods.json present, host config compatible' do
      it 'returns [config, :snapshot] without raising' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          config, source = described_class.resolve(ollama_config, artifact: artifact)
          expect(config).to eq(ollama_config)
          expect(source).to eq(:snapshot)
        end
      end

      it 'does not mutate the config object' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          original_provider = ollama_config.embedding_provider
          described_class.resolve(ollama_config, artifact: artifact)
          expect(ollama_config.embedding_provider).to eq(original_provider)
        end
      end
    end

    context 'woods.json present, host has no provider — populates config from snapshot' do
      it 'returns [config, :snapshot] and sets embedding_provider' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          config, source = described_class.resolve(blank_config, artifact: artifact)
          expect(config.embedding_provider).to eq(:ollama)
          expect(source).to eq(:snapshot)
        end
      end

      it 'sets store types from the snapshot' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          config, = described_class.resolve(blank_config, artifact: artifact)
          expect(config.vector_store).to eq(:in_memory)
          expect(config.metadata_store).to eq(:in_memory)
          expect(config.graph_store).to eq(:in_memory)
        end
      end

      it 'sets embedding_options with host and model from the snapshot' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          config, = described_class.resolve(blank_config, artifact: artifact)
          expect(config.embedding_options[:host]).to eq('http://localhost:11434')
          expect(config.embedding_options[:model]).to eq('nomic-embed-text')
        end
      end

      it 'maps OpenAI class name back to :openai symbol when OPENAI_API_KEY is in env' do
        Dir.mktmpdir do |dir|
          openai_hash = woods_json_hash.merge(
            'embedding_provider' => {
              'class' => 'Woods::Embedding::Provider::OpenAI',
              'model' => 'text-embedding-3-small',
              'dimension' => 1536
            }
          )
          write_woods_json(dir, openai_hash)
          artifact = Woods::IndexArtifact.new(dir)
          config, = described_class.resolve(
            blank_config, artifact: artifact, env: { 'OPENAI_API_KEY' => 'sk-test' }
          )
          expect(config.embedding_provider).to eq(:openai)
          expect(config.embedding_options[:api_key]).to eq('sk-test')
        end
      end

      it 'raises MissingCredential when OpenAI snapshot is loaded without OPENAI_API_KEY' do
        Dir.mktmpdir do |dir|
          openai_hash = woods_json_hash.merge(
            'embedding_provider' => {
              'class' => 'Woods::Embedding::Provider::OpenAI',
              'model' => 'text-embedding-3-small',
              'dimension' => 1536
            }
          )
          write_woods_json(dir, openai_hash)
          artifact = Woods::IndexArtifact.new(dir)
          expect do
            described_class.resolve(blank_config, artifact: artifact, env: {})
          end.to raise_error(Woods::MCP::MissingCredential, /OPENAI_API_KEY/)
        end
      end
    end

    context 'woods.json present but schema_version is unsupported' do
      it 'raises Woods::MCP::UnsupportedArtifact' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir, woods_json_hash.merge('schema_version' => 99))
          artifact = Woods::IndexArtifact.new(dir)
          expect { described_class.resolve(blank_config, artifact: artifact) }
            .to raise_error(Woods::MCP::UnsupportedArtifact, /99/)
        end
      end
    end

    context 'woods.json present, live config has different dimension' do
      it 'raises Woods::MCP::DimensionMismatch' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          cfg = Woods::Configuration.new
          cfg.vector_store = :in_memory
          cfg.metadata_store = :in_memory
          cfg.graph_store = :in_memory
          cfg.embedding_provider = :ollama
          cfg.embedding_options = { host: 'http://localhost:11434', model: 'nomic-embed-text', dimension: 1536 }
          expect { described_class.resolve(cfg, artifact: artifact) }
            .to raise_error(Woods::MCP::DimensionMismatch)
        end
      end
    end

    context 'woods.json present, host omits declared dimension (Ollama case)' do
      it 'probes the live provider and validates against stored dimension' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          cfg = Woods::Configuration.new
          cfg.vector_store = :in_memory
          cfg.metadata_store = :in_memory
          cfg.graph_store = :in_memory
          cfg.embedding_provider = :ollama
          cfg.embedding_options = { host: 'http://localhost:11434', model: 'nomic-embed-text' }

          probe_provider = instance_double(Woods::Embedding::Provider::Ollama, dimensions: 768)
          allow_any_instance_of(Woods::Builder).to receive(:build_embedding_provider).and_return(probe_provider)

          expect { described_class.resolve(cfg, artifact: artifact) }.not_to raise_error
        end
      end

      it 'falls back gracefully when the provider probe raises, surfacing a typed mismatch' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          cfg = Woods::Configuration.new
          cfg.vector_store = :in_memory
          cfg.metadata_store = :in_memory
          cfg.graph_store = :in_memory
          cfg.embedding_provider = :ollama
          cfg.embedding_options = { host: 'http://localhost:11434', model: 'nomic-embed-text' }

          probe_provider = instance_double(Woods::Embedding::Provider::Ollama)
          allow(probe_provider).to receive(:dimensions).and_raise(Errno::ECONNREFUSED)
          allow_any_instance_of(Woods::Builder).to receive(:build_embedding_provider).and_return(probe_provider)

          # Untyped network error must not escape — it's converted to a typed
          # DimensionMismatch (0 vs stored 768) the caller's BootstrapError
          # rescue can handle.
          expect { described_class.resolve(cfg, artifact: artifact) }
            .to raise_error(Woods::MCP::DimensionMismatch)
        end
      end
    end

    context 'woods.json present, live config has different provider model' do
      it 'raises Woods::MCP::ConfigMismatch' do
        Dir.mktmpdir do |dir|
          write_woods_json(dir)
          artifact = Woods::IndexArtifact.new(dir)
          cfg = Woods::Configuration.new
          cfg.vector_store = :in_memory
          cfg.metadata_store = :in_memory
          cfg.graph_store = :in_memory
          cfg.embedding_provider = :ollama
          cfg.embedding_options = { host: 'http://localhost:11434', model: 'mxbai-embed-large', dimension: 768 }
          expect { described_class.resolve(cfg, artifact: artifact) }
            .to raise_error(Woods::MCP::ConfigMismatch)
        end
      end
    end

    context 'no woods.json, host has embedding_provider set' do
      it 'returns [config, :host_config] without raising' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          config, source = described_class.resolve(ollama_config, artifact: artifact)
          expect(config).to eq(ollama_config)
          expect(source).to eq(:host_config)
        end
      end
    end

    context 'no woods.json, no host provider, no credentials (extract-only default)' do
      it 'returns [config, :autodetect] in pattern-only mode instead of raising (#138)' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          config, source = described_class.resolve(blank_config,
                                                   artifact: artifact,
                                                   env: {},
                                                   ollama_probe: -> { false })
          expect(config.embedding_provider).to be_nil
          expect(source).to eq(:autodetect)
        end
      end
    end

    context 'no woods.json, no host provider, WOODS_REQUIRE_INDEX=1 (strict opt-in)' do
      it 'raises Woods::MCP::MissingArtifact naming the strict flag' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          env = { 'WOODS_REQUIRE_INDEX' => '1' }
          expect { described_class.resolve(blank_config, artifact: artifact, env: env, ollama_probe: -> { false }) }
            .to raise_error(Woods::MCP::MissingArtifact, /WOODS_REQUIRE_INDEX/)
        end
      end
    end

    context 'no woods.json, no host provider, OPENAI_API_KEY set' do
      it 'auto-detects :openai by default (no opt-in flag required)' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          env = { 'OPENAI_API_KEY' => 'sk-test' }
          config, source = described_class.resolve(blank_config, artifact: artifact, env: env)
          expect(config.embedding_provider).to eq(:openai)
          expect(source).to eq(:autodetect)
        end
      end
    end

    context 'no woods.json, no host provider, Ollama reachable' do
      it 'auto-detects :ollama by default (no opt-in flag required)' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          env = { 'OLLAMA_BASE_URL' => 'http://127.0.0.1:11434' }
          config, source = described_class.resolve(blank_config,
                                                   artifact: artifact,
                                                   env: env,
                                                   ollama_probe: -> { true })
          expect(config.embedding_provider).to eq(:ollama)
          expect(source).to eq(:autodetect)
        end
      end
    end

    context 'legacy WOODS_ALLOW_AUTODETECT=1 (back-compat no-op)' do
      it 'still auto-detects without error' do
        Dir.mktmpdir do |dir|
          artifact = Woods::IndexArtifact.new(dir)
          env = { 'WOODS_ALLOW_AUTODETECT' => '1' }
          config, source = described_class.resolve(blank_config,
                                                   artifact: artifact,
                                                   env: env,
                                                   ollama_probe: -> { false })
          expect(config.embedding_provider).to be_nil
          expect(source).to eq(:autodetect)
        end
      end
    end

    context 'nil artifact (no output_dir configured)' do
      it 'boots in pattern-only mode by default when host has no provider' do
        config, source = described_class.resolve(blank_config, artifact: nil, env: {}, ollama_probe: -> { false })
        expect(config.embedding_provider).to be_nil
        expect(source).to eq(:autodetect)
      end

      it 'raises Woods::MCP::MissingArtifact under WOODS_REQUIRE_INDEX=1' do
        expect do
          described_class.resolve(blank_config, artifact: nil, env: { 'WOODS_REQUIRE_INDEX' => '1' },
                                                ollama_probe: -> { false })
        end.to raise_error(Woods::MCP::MissingArtifact)
      end

      it 'returns [config, :host_config] when host has a provider' do
        config, source = described_class.resolve(ollama_config, artifact: nil)
        expect(config).to eq(ollama_config)
        expect(source).to eq(:host_config)
      end
    end
  end
end
