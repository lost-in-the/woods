# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/errors'
require 'woods/resolved_config'

RSpec.describe Woods::ResolvedConfig do
  let(:v1_hash) do
    {
      'schema_version' => 1,
      'gem_version' => '1.2.0',
      'created_at' => '2026-04-23T03:42:17Z',
      'embedding_provider' => {
        'class' => 'Woods::Embedding::Provider::Ollama',
        'model' => 'nomic-embed-text',
        'host' => 'http://host.docker.internal:11434',
        'num_ctx' => 2048,
        'read_timeout' => 120,
        'dimension' => 768
      },
      'stores' => {
        'vector_store' => 'in_memory',
        'metadata_store' => 'in_memory',
        'graph_store' => 'in_memory'
      }
    }
  end

  describe '.from_hash' do
    it 'parses a valid v1 snapshot' do
      config = described_class.from_hash(v1_hash)
      expect(config).to be_a(described_class)
      expect(config.schema_version).to eq(1)
      expect(config.gem_version).to eq('1.2.0')
      expect(config.dimension).to eq(768)
      expect(config.embedding_provider[:model]).to eq('nomic-embed-text')
      expect(config.stores[:vector_store]).to eq(:in_memory)
    end

    it 'accepts symbol keys' do
      sym_hash = v1_hash.transform_keys(&:to_sym).merge(
        embedding_provider: v1_hash['embedding_provider'].transform_keys(&:to_sym),
        stores: v1_hash['stores'].transform_keys(&:to_sym)
      )
      config = described_class.from_hash(sym_hash)
      expect(config.dimension).to eq(768)
    end

    it 'parses created_at as Time' do
      config = described_class.from_hash(v1_hash)
      expect(config.created_at).to be_a(Time)
      expect(config.created_at.utc.strftime('%Y-%m-%dT%H:%M:%SZ')).to eq('2026-04-23T03:42:17Z')
    end

    it 'raises UnsupportedArtifact on schema_version 0' do
      bad = v1_hash.merge('schema_version' => 0)
      expect { described_class.from_hash(bad) }
        .to raise_error(Woods::MCP::UnsupportedArtifact) do |e|
          expect(e.details[:found]).to eq(0)
          expect(e.details[:supported]).to eq(1)
        end
    end

    it 'raises UnsupportedArtifact on schema_version 2+' do
      bad = v1_hash.merge('schema_version' => 2)
      expect { described_class.from_hash(bad) }
        .to raise_error(Woods::MCP::UnsupportedArtifact) do |e|
          expect(e.details[:found]).to eq(2)
          expect(e.details[:supported]).to eq(1)
        end
    end

    it 'raises UnsupportedArtifact when schema_version is missing' do
      bad = v1_hash.except('schema_version')
      expect { described_class.from_hash(bad) }
        .to raise_error(Woods::MCP::UnsupportedArtifact)
    end

    it 'stores num_ctx and read_timeout in the provider hash' do
      config = described_class.from_hash(v1_hash)
      expect(config.embedding_provider[:num_ctx]).to eq(2048)
      expect(config.embedding_provider[:read_timeout]).to eq(120)
    end
  end

  describe '#dimension' do
    it 'returns the integer dimension from the provider hash' do
      config = described_class.from_hash(v1_hash)
      expect(config.dimension).to eq(768)
    end
  end

  describe '#provider_signature' do
    it 'includes provider class short name, model, and host' do
      config = described_class.from_hash(v1_hash)
      expect(config.provider_signature).to eq('Ollama/nomic-embed-text@http://host.docker.internal:11434')
    end

    it 'omits host when absent' do
      no_host = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].except('host')
      )
      config = described_class.from_hash(no_host)
      expect(config.provider_signature).to eq('Ollama/nomic-embed-text')
    end
  end

  describe '#matches?' do
    let(:config) { described_class.from_hash(v1_hash) }

    it 'returns true when provider and stores match' do
      other = described_class.from_hash(v1_hash)
      expect(config.matches?(other)).to be(true)
    end

    it 'returns false when provider class differs' do
      diff = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge(
          'class' => 'Woods::Embedding::Provider::OpenAI'
        )
      )
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(false)
    end

    it 'returns false when model differs' do
      diff = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('model' => 'mxbai-embed-large')
      )
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(false)
    end

    it 'returns false when dimension differs' do
      diff = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('dimension' => 1536)
      )
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(false)
    end

    it 'returns false when vector_store type differs' do
      diff = v1_hash.merge('stores' => v1_hash['stores'].merge('vector_store' => 'qdrant'))
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(false)
    end

    it 'ignores gem_version differences' do
      diff = v1_hash.merge('gem_version' => '9.9.9')
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(true)
    end

    it 'ignores read_timeout differences' do
      diff = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('read_timeout' => 999)
      )
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(true)
    end

    it 'ignores created_at differences' do
      diff = v1_hash.merge('created_at' => '2020-01-01T00:00:00Z')
      other = described_class.from_hash(diff)
      expect(config.matches?(other)).to be(true)
    end
  end

  describe '#assert_compatible!' do
    let(:config) { described_class.from_hash(v1_hash) }

    it 'is a no-op when configs match' do
      stored = described_class.from_hash(v1_hash)
      expect { config.assert_compatible!(stored) }.not_to raise_error
    end

    it 'raises DimensionMismatch when dimensions differ' do
      stored_hash = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('dimension' => 1536)
      )
      stored = described_class.from_hash(stored_hash)

      expect { config.assert_compatible!(stored) }
        .to raise_error(Woods::MCP::DimensionMismatch) do |e|
          expect(e.details[:expected]).to eq(1536)
          expect(e.details[:actual]).to eq(768)
          expect(e.details[:stored_at]).to be_a(String)
        end
    end

    it 'raises ConfigMismatch when provider class differs' do
      stored_hash = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge(
          'class' => 'Woods::Embedding::Provider::OpenAI'
        )
      )
      stored = described_class.from_hash(stored_hash)

      expect { config.assert_compatible!(stored) }
        .to raise_error(Woods::MCP::ConfigMismatch) do |e|
          expect(e.details[:host]).to include('Ollama')
          expect(e.details[:stored]).to include('OpenAI')
        end
    end

    it 'raises ConfigMismatch when model differs' do
      stored_hash = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('model' => 'mxbai-embed-large')
      )
      stored = described_class.from_hash(stored_hash)

      expect { config.assert_compatible!(stored) }
        .to raise_error(Woods::MCP::ConfigMismatch)
    end

    it 'checks dimension before provider class' do
      stored_hash = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge(
          'class' => 'Woods::Embedding::Provider::OpenAI',
          'dimension' => 1536
        )
      )
      stored = described_class.from_hash(stored_hash)

      expect { config.assert_compatible!(stored) }.to raise_error(Woods::MCP::DimensionMismatch)
    end
  end

  describe '#to_snapshot_json' do
    it 'returns a Hash with string keys' do
      config = described_class.from_hash(v1_hash)
      snap = config.to_snapshot_json
      expect(snap).to be_a(Hash)
      expect(snap.keys).to all(be_a(String))
    end

    it 'round-trips through from_hash' do
      config = described_class.from_hash(v1_hash)
      round_tripped = described_class.from_hash(config.to_snapshot_json)

      expect(round_tripped.dimension).to eq(config.dimension)
      expect(round_tripped.provider_signature).to eq(config.provider_signature)
      expect(round_tripped.stores).to eq(config.stores)
      expect(round_tripped.gem_version).to eq(config.gem_version)
    end

    it 'produces JSON-serializable output' do
      config = described_class.from_hash(v1_hash)
      expect { JSON.generate(config.to_snapshot_json) }.not_to raise_error
    end
  end

  describe 'immutability' do
    it 'is frozen after construction' do
      config = described_class.from_hash(v1_hash)
      expect(config).to be_frozen
    end

    it 'has a frozen embedding_provider hash' do
      config = described_class.from_hash(v1_hash)
      expect(config.embedding_provider).to be_frozen
    end

    it 'has a frozen stores hash' do
      config = described_class.from_hash(v1_hash)
      expect(config.stores).to be_frozen
    end

    it 'freezes nested string values, not just the containing hash' do
      # A frozen hash still allows `hash[:model] << "-v2"` if the string
      # itself is mutable — build the input with unfrozen strings to prove
      # deep_freeze reaches them.
      mutable = v1_hash.merge(
        'embedding_provider' => v1_hash['embedding_provider'].merge('model' => +'nomic-embed-text')
      )
      config = described_class.from_hash(mutable)

      model = config.embedding_provider[:model]
      expect(model).to be_frozen
      expect { model << '-v2' }.to raise_error(FrozenError)
    end
  end

  describe '.from_configuration' do
    let(:host_config) do
      instance_double(
        Woods::Configuration,
        embedding_provider: :ollama,
        embedding_model: 'nomic-embed-text',
        embedding_options: { host: 'http://ollama:11434' },
        vector_store: :in_memory,
        metadata_store: :in_memory,
        graph_store: :in_memory
      )
    end

    it 'probes the live provider for its dimension when declared config omits it' do
      provider = instance_double(Woods::Embedding::Provider::Ollama, dimensions: 768)

      resolved = described_class.from_configuration(host_config, provider: provider)

      expect(resolved.dimension).to eq(768)
    end

    it 'prefers a declared dimension over the live provider probe' do
      declared = host_config.embedding_options.merge(dimension: 1024)
      allow(host_config).to receive(:embedding_options).and_return(declared)
      provider = instance_double(Woods::Embedding::Provider::Ollama)

      resolved = described_class.from_configuration(host_config, provider: provider)

      expect(resolved.dimension).to eq(1024)
      expect(provider).not_to have_received(:dimensions) if provider.respond_to?(:dimensions)
    end

    it 'falls back to zero when no provider is supplied and config omits dimension' do
      resolved = described_class.from_configuration(host_config)

      expect(resolved.dimension).to eq(0)
    end
  end
end
