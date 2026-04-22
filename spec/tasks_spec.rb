# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/tasks'

RSpec.describe Woods::Tasks do
  describe '.build_embed_indexer' do
    let(:fake_provider) { instance_double(Woods::Embedding::Provider::Ollama) }
    let(:fake_vector_store) { instance_double(Woods::Storage::VectorStore::InMemory) }
    let(:captured) { {} }

    before do
      allow_any_instance_of(Woods::Builder).to receive(:build_embedding_provider).and_return(fake_provider)
      allow_any_instance_of(Woods::Builder).to receive(:build_vector_store).and_return(fake_vector_store)

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

      expect(captured[:provider]).to be(fake_provider)
      expect(captured[:vector_store]).to be(fake_vector_store)
      expect(captured[:text_preparer]).to be_a(Woods::Embedding::TextPreparer)
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
