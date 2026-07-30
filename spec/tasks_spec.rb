# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/tasks'

RSpec.describe Woods::Tasks do
  describe '.build_embed_indexer' do
    let(:fake_provider) { instance_double(Woods::Embedding::Provider::Ollama) }
    let(:fake_vector_store) { instance_double(Woods::Storage::VectorStore::InMemory) }
    let(:fake_text_preparer) { instance_double(Woods::Embedding::TextPreparer) }
    let(:fake_chunker) { instance_double(Woods::Chunking::SemanticChunker) }
    let(:captured) { {} }

    # Guard against random-seed ordering: this spec file mocks at the
    # Builder level, which needs Woods.configuration to be non-nil when
    # build_embed_indexer runs. Other specs in the suite happen to call
    # Woods.configure, but we cannot rely on order — Ruby 3.1 CI already
    # tripped on this under a different seed.
    before do
      Woods.configure { |c| c.output_dir ||= '/tmp/woods-tasks-default' }

      allow_any_instance_of(Woods::Builder).to receive(:build_embedding_provider).and_return(fake_provider)
      allow_any_instance_of(Woods::Builder).to receive(:build_vector_store).and_return(fake_vector_store)
      allow_any_instance_of(Woods::Builder).to receive(:build_text_preparer).and_return(fake_text_preparer)
      allow_any_instance_of(Woods::Builder).to receive(:build_chunker).and_return(fake_chunker)

      allow(Woods::Embedding::Indexer).to receive(:new).and_wrap_original do |original, **kwargs|
        captured.merge!(kwargs)
        original.call(**kwargs)
      end
    end

    # Regression — the rake tasks used to hardcode Ollama.new / InMemory.new and
    # ignored Woods.configuration entirely, so admin's host.docker.internal URL
    # for a container-hosted app was discarded and the provider fell back to
    # localhost:11434 inside the container.
    it 'wires the indexer with the configured provider and vector store' do
      described_class.build_embed_indexer

      expect(captured[:provider].provider).to be(fake_provider)
      expect(captured[:vector_store]).to be(fake_vector_store)
      expect(captured[:text_preparer]).to be(fake_text_preparer)
      expect(captured[:chunker]).to be(fake_chunker)
    end

    # B-076 / #188 — the raw provider used to be handed straight to the
    # Indexer, so a single OpenAI 429 mid-run raised out of embed_batch and
    # aborted the whole woods:embed run (discarding every embedding already
    # paid for on the dump-at-end presets).
    it 'wraps the provider in RetryableProvider with its own circuit breaker' do
      described_class.build_embed_indexer

      expect(captured[:provider]).to be_a(Woods::Resilience::RetryableProvider)
      expect(captured[:provider].circuit_breaker).to be_a(Woods::Resilience::CircuitBreaker)
    end

    it 'builds a fresh breaker per indexer (no shared breaker state)' do
      described_class.build_embed_indexer
      first_breaker = captured[:provider].circuit_breaker

      described_class.build_embed_indexer

      expect(captured[:provider].circuit_breaker).not_to be(first_breaker)
    end

    # Tokenizer calibration dispatches on the provider's concrete class, so
    # the preparer and chunker must be tuned against the raw provider, not
    # the resilience wrapper.
    it 'tunes the text preparer and chunker against the raw provider' do
      expect_any_instance_of(Woods::Builder).to receive(:build_text_preparer)
        .with(fake_provider).and_return(fake_text_preparer)
      expect_any_instance_of(Woods::Builder).to receive(:build_chunker)
        .with(fake_provider).and_return(fake_chunker)

      described_class.build_embed_indexer
    end

    it 'uses config.output_dir by default' do
      Woods.configure { |c| c.output_dir = '/tmp/woods-tasks-spec' }

      described_class.build_embed_indexer

      expect(captured[:output_dir]).to eq('/tmp/woods-tasks-spec')
    end

    it 'prefers WOODS_OUTPUT env var over config.output_dir' do
      Woods.configure { |c| c.output_dir = '/tmp/config-output' }
      ENV['WOODS_OUTPUT'] = '/tmp/env-output'

      described_class.build_embed_indexer

      expect(captured[:output_dir]).to eq('/tmp/env-output')
    ensure
      ENV.delete('WOODS_OUTPUT')
    end
  end

  describe '.print_embed_stats' do
    let(:stats) { { processed: 5, skipped: 2, errors: 0 } }

    it 'prints a "complete" header in :full mode' do
      expect { described_class.print_embed_stats(stats, mode: :full) }
        .to output(/Embedding complete!/).to_stdout
    end

    it 'prints an "incremental" header in :incremental mode' do
      expect { described_class.print_embed_stats(stats, mode: :incremental) }
        .to output(/Incremental embedding complete!/).to_stdout
    end

    it 'prints the stats hash values' do
      expect { described_class.print_embed_stats(stats, mode: :full) }
        .to output(/Processed: 5.*Skipped:\s+2.*Errors:\s+0/m).to_stdout
    end
  end
end
