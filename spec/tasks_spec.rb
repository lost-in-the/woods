# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/tasks'

RSpec.describe Woods::Tasks do
  describe '.build_embed_indexer' do
    let(:fake_provider) { instance_double(Woods::Embedding::Provider::Ollama, dimensions: 384) }
    let(:fake_vector_store) { instance_double(Woods::Storage::VectorStore::InMemory) }
    let(:fake_text_preparer) { instance_double(Woods::Embedding::TextPreparer) }
    let(:fake_chunker) { instance_double(Woods::Chunking::SemanticChunker) }
    let(:captured) { {} }

    # These examples mutate the *global* Woods.configuration, so they restore
    # it. Without that, `output_dir` leaked into every spec that ran afterwards
    # in the same process — and `spec/mcp/server_spec.rb` mkdirs that path for
    # its pipeline lock, so under some random seeds it tried to create a
    # hardcoded /tmp directory and cascaded five failures out of an unrelated
    # file. The paths below are under Dir.tmpdir for the same reason: a
    # hardcoded /tmp is not writable everywhere the suite runs.
    around do |example|
      previous = Woods.configuration
      example.run
    ensure
      Woods.configuration = previous
    end

    before do
      # This file mocks at the Builder level, which needs Woods.configuration
      # to be non-nil when build_embed_indexer runs. Other specs happen to call
      # Woods.configure, but order is random — Ruby 3.1 CI tripped on this once.
      Woods.configure { |c| c.output_dir ||= File.join(Dir.tmpdir, 'woods-tasks-default') }

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

    it 'passes the provider dimensions when constructing the vector store' do
      allow(fake_provider).to receive(:dimensions).and_return(384)
      expect_any_instance_of(Woods::Builder).to receive(:build_vector_store)
        .with(dimensions: 384).and_return(fake_vector_store)

      described_class.build_embed_indexer
    end

    it 'uses config.output_dir by default' do
      configured = File.join(Dir.tmpdir, 'woods-tasks-spec')
      Woods.configure { |c| c.output_dir = configured }

      described_class.build_embed_indexer

      expect(captured[:output_dir]).to eq(configured)
    end

    it 'prefers WOODS_OUTPUT env var over config.output_dir' do
      Woods.configure { |c| c.output_dir = File.join(Dir.tmpdir, 'woods-config-output') }
      env_output = File.join(Dir.tmpdir, 'woods-env-output')
      ENV['WOODS_OUTPUT'] = env_output

      described_class.build_embed_indexer

      expect(captured[:output_dir]).to eq(env_output)
    ensure
      ENV.delete('WOODS_OUTPUT')
    end

    # #214 / B-101. Six documents claimed IndexValidator detected dimension
    # mismatches; it never did, and nothing checked provider-vs-store width on
    # a durable backend at all. Switching embedding_model left the old table or
    # collection in place (both ensure_* calls are idempotent), so the run
    # embedded everything and only then failed per-row with a server error
    # naming no remedy.
    describe 'dimension pre-flight' do
      # A real Pgvector, not a double: the error message interpolates
      # `vector_store.class`, and a double would report its own class and
      # quietly make the assertion meaningless.
      let(:durable_store) do
        connection_class = Class.new do
          def execute(_sql) = []
          def quote(value) = "'#{value}'"
        end
        store = Woods::Storage::VectorStore::Pgvector.new(connection: connection_class.new, dimensions: 768)
        allow(store).to receive(:stored_dimensions).and_return(stored_dimensions)
        store
      end
      let(:stored_dimensions) { 384 }

      before do
        allow(fake_provider).to receive(:dimensions).and_return(768)
        allow_any_instance_of(Woods::Builder).to receive(:build_vector_store).and_return(durable_store)
      end

      it 'refuses before building the indexer when the widths disagree' do
        expect { described_class.build_embed_indexer }
          .to raise_error(Woods::MCP::DimensionMismatch, /holds 384-dimension vectors.*produces 768/m)
      end

      it 'names both dimensions and the store in the error details' do
        described_class.build_embed_indexer
      rescue Woods::MCP::DimensionMismatch => e
        expect(e.details).to include(stored_dimension: 384, provider_dimension: 768)
        expect(e.details[:store]).to match(/Pgvector/)
      end

      it 'gives the remedy, not just the discrepancy' do
        described_class.build_embed_indexer
      rescue Woods::MCP::DimensionMismatch => e
        expect(e.message).to match(/woods:extract && woods:embed/)
      end

      context 'when the widths agree' do
        let(:stored_dimensions) { 768 }

        it 'builds the indexer' do
          expect { described_class.build_embed_indexer }.not_to raise_error
        end
      end

      # A store that does not exist yet reports nil. That is the first-ever
      # embed, not a mismatch.
      context 'when the store cannot report a width' do
        let(:stored_dimensions) { nil }

        it 'builds the indexer' do
          expect { described_class.build_embed_indexer }.not_to raise_error
        end
      end

      # The in-memory store has no stored_dimensions at all; the dump path
      # carries its own check in Snapshotter::Vector.
      it 'skips stores that do not implement stored_dimensions' do
        allow_any_instance_of(Woods::Builder).to receive(:build_vector_store).and_return(fake_vector_store)

        expect { described_class.build_embed_indexer }.not_to raise_error
      end
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
