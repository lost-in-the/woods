# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/observability/health_check'

RSpec.describe CodebaseIndex::Observability::HealthCheck do
  let(:vector_store) { instance_double('VectorStore', count: 10) }
  let(:metadata_store) { instance_double('MetadataStore', count: 20) }
  let(:embedding_provider) { instance_double('EmbeddingProvider', embed: [0.1, 0.2, 0.3]) }

  describe '#run' do
    context 'when all components are healthy' do
      let(:health_check) do
        described_class.new(
          vector_store: vector_store,
          metadata_store: metadata_store,
          embedding_provider: embedding_provider
        )
      end

      it 'returns a healthy status' do
        status = health_check.run

        expect(status.healthy?).to be true
      end

      it 'reports all components as ok' do
        status = health_check.run

        expect(status.components[:vector_store]).to eq(:ok)
        expect(status.components[:metadata_store]).to eq(:ok)
        expect(status.components[:embedding_provider]).to eq(:ok)
      end
    end

    context 'when a component raises an error' do
      let(:failing_store) { instance_double('VectorStore') }

      before do
        allow(failing_store).to receive(:count).and_raise(StandardError, 'connection refused')
      end

      let(:health_check) do
        described_class.new(
          vector_store: failing_store,
          metadata_store: metadata_store,
          embedding_provider: embedding_provider
        )
      end

      it 'returns an unhealthy status' do
        status = health_check.run

        expect(status.healthy?).to be false
      end

      it 'reports the failing component as error' do
        status = health_check.run

        expect(status.components[:vector_store]).to eq(:error)
        expect(status.components[:metadata_store]).to eq(:ok)
      end
    end

    context 'when a component is nil (not configured)' do
      let(:health_check) do
        described_class.new(
          vector_store: nil,
          metadata_store: metadata_store,
          embedding_provider: nil
        )
      end

      it 'returns healthy (unconfigured components are ignored)' do
        status = health_check.run

        expect(status.healthy?).to be true
      end

      it 'reports nil components as not_configured' do
        status = health_check.run

        expect(status.components[:vector_store]).to eq(:not_configured)
        expect(status.components[:embedding_provider]).to eq(:not_configured)
        expect(status.components[:metadata_store]).to eq(:ok)
      end
    end

    context 'when no components are configured' do
      let(:health_check) { described_class.new }

      it 'returns healthy' do
        status = health_check.run

        expect(status.healthy?).to be true
      end

      it 'reports all components as not_configured' do
        status = health_check.run

        expect(status.components[:vector_store]).to eq(:not_configured)
        expect(status.components[:metadata_store]).to eq(:not_configured)
        expect(status.components[:embedding_provider]).to eq(:not_configured)
      end
    end

    context 'when embedding provider is probed' do
      it 'calls embed with a test string' do
        health_check = described_class.new(embedding_provider: embedding_provider)
        health_check.run

        expect(embedding_provider).to have_received(:embed).with('test')
      end
    end

    context 'when stores are probed' do
      it 'calls count on vector_store' do
        health_check = described_class.new(vector_store: vector_store)
        health_check.run

        expect(vector_store).to have_received(:count)
      end

      it 'calls count on metadata_store' do
        health_check = described_class.new(metadata_store: metadata_store)
        health_check.run

        expect(metadata_store).to have_received(:count)
      end
    end
  end

  describe CodebaseIndex::Observability::HealthCheck::HealthStatus do
    it 'is a struct with healthy? and components' do
      status = described_class.new(healthy?: true, components: { vector_store: :ok })

      expect(status.healthy?).to be true
      expect(status.components).to eq({ vector_store: :ok })
    end
  end
end
