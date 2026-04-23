# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/errors'

RSpec.describe 'Woods::MCP exception hierarchy' do
  describe Woods::MCP::BootstrapError do
    it 'inherits from Woods::Error' do
      expect(described_class.superclass).to eq(Woods::Error)
    end

    it 'does not inherit from Woods::ConfigurationError' do
      expect(described_class.ancestors).not_to include(Woods::ConfigurationError)
    end

    it 'accepts a message and details hash' do
      error = described_class.new('boom', details: { foo: 'bar' })
      expect(error.message).to eq('boom')
      expect(error.details).to eq({ foo: 'bar' })
    end

    it 'defaults details to empty hash' do
      error = described_class.new('boom')
      expect(error.details).to eq({})
    end
  end

  describe Woods::MCP::MissingCredential do
    it 'inherits from BootstrapError' do
      expect(described_class.superclass).to eq(Woods::MCP::BootstrapError)
    end

    it 'carries structured details' do
      error = described_class.new('key missing', details: { credential: 'OPENAI_API_KEY' })
      expect(error.details[:credential]).to eq('OPENAI_API_KEY')
    end
  end

  describe Woods::MCP::ConfigMismatch do
    it 'inherits from BootstrapError' do
      expect(described_class.superclass).to eq(Woods::MCP::BootstrapError)
    end

    it 'carries stored and host detail keys' do
      error = described_class.new('mismatch', details: { stored: 'Ollama', host: 'OpenAI' })
      expect(error.details[:stored]).to eq('Ollama')
      expect(error.details[:host]).to eq('OpenAI')
    end
  end

  describe Woods::MCP::DimensionMismatch do
    it 'inherits from BootstrapError' do
      expect(described_class.superclass).to eq(Woods::MCP::BootstrapError)
    end

    it 'carries expected and actual dimension details' do
      error = described_class.new('dim mismatch', details: { expected: 768, actual: 1536 })
      expect(error.details[:expected]).to eq(768)
      expect(error.details[:actual]).to eq(1536)
    end
  end

  describe Woods::MCP::UnsupportedArtifact do
    it 'inherits from BootstrapError' do
      expect(described_class.superclass).to eq(Woods::MCP::BootstrapError)
    end

    it 'carries artifact_version and max_supported' do
      error = described_class.new('too new', details: { artifact_version: 3, max_supported: 1 })
      expect(error.details[:artifact_version]).to eq(3)
      expect(error.details[:max_supported]).to eq(1)
    end
  end

  describe Woods::MCP::MissingArtifact do
    it 'inherits from BootstrapError' do
      expect(described_class.superclass).to eq(Woods::MCP::BootstrapError)
    end

    it 'carries output_dir in details' do
      error = described_class.new('no woods.json', details: { output_dir: '/app/tmp/woods' })
      expect(error.details[:output_dir]).to eq('/app/tmp/woods')
    end
  end

  describe Woods::MCP::ProviderUnreachable do
    it 'inherits from Woods::Error' do
      expect(described_class.superclass).to eq(Woods::Error)
    end

    it 'does NOT inherit from BootstrapError' do
      expect(described_class.ancestors).not_to include(Woods::MCP::BootstrapError)
    end

    it 'accepts message and details' do
      error = described_class.new('refused', details: { url: 'http://localhost:11434', reason: 'connection refused' })
      expect(error.message).to eq('refused')
      expect(error.details[:url]).to eq('http://localhost:11434')
      expect(error.details[:reason]).to eq('connection refused')
    end

    it 'defaults details to empty hash' do
      error = described_class.new('refused')
      expect(error.details).to eq({})
    end
  end

  describe Woods::Storage::InapplicableBackend do
    it 'inherits from Woods::Error' do
      expect(described_class.superclass).to eq(Woods::Error)
    end

    it 'does NOT inherit from BootstrapError' do
      expect(described_class.ancestors).not_to include(Woods::MCP::BootstrapError)
    end
  end

  describe 'BootstrapError rescue semantics' do
    it 'catches all BootstrapError subclasses with rescue BootstrapError' do
      subclasses = [
        Woods::MCP::MissingCredential,
        Woods::MCP::ConfigMismatch,
        Woods::MCP::DimensionMismatch,
        Woods::MCP::UnsupportedArtifact,
        Woods::MCP::MissingArtifact
      ]

      subclasses.each do |klass|
        expect { raise klass, 'test' }.to raise_error(Woods::MCP::BootstrapError)
      end
    end

    it 'does not catch ProviderUnreachable with rescue BootstrapError' do
      expect do
        raise Woods::MCP::ProviderUnreachable, 'test'
      rescue Woods::MCP::BootstrapError
        :caught_as_bootstrap
      end.to raise_error(Woods::MCP::ProviderUnreachable)
    end
  end
end
