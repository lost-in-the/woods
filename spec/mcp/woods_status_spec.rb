# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/index_reader'

RSpec.describe 'woods_status tool' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:reader) { Woods::MCP::IndexReader.new(fixture_dir) }

  describe 'Woods::MCP::Server.build_status' do
    subject(:status) { Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: fixture_dir) }

    it 'reports server identity with the current gem version' do
      expect(status[:server]).to include(name: 'woods', version: Woods::VERSION, index_dir: fixture_dir.to_s)
    end

    it 'surfaces extraction metadata from the manifest' do
      expect(status[:index]).to include(
        extracted_at: '2026-01-15T12:00:00Z',
        rails_version: '8.1.2',
        ruby_version: '4.0.1'
      )
      expect(status[:index][:counts]).to include('models' => 2, 'controllers' => 1)
    end

    it 'computes staleness as a non-negative integer of seconds' do
      expect(status[:index][:staleness_seconds]).to be_a(Integer)
      expect(status[:index][:staleness_seconds]).to be >= 0
    end

    it 'reports ready=true when the index has units' do
      expect(status[:ready]).to be(true)
    end

    it 'reports retriever.configured=false when no retriever is passed' do
      expect(status[:retriever]).to include(configured: false, class: nil)
    end

    it 'reports retriever.configured=true when a retriever is present' do
      fake = Class.new.new
      s = Woods::MCP::Server.build_status(reader: reader, retriever: fake, index_dir: fixture_dir)
      expect(s[:retriever][:configured]).to be(true)
    end

    it 'exposes feature flags from Woods.configuration' do
      expect(status[:features]).to include(
        :embedding_model, :session_tracer_enabled, :snapshots_enabled,
        :notion_configured
      )
    end

    it 'omits console_mcp_enabled (always wrong — index MCP cannot see Rails-side config)' do
      expect(status[:features]).not_to have_key(:console_mcp_enabled)
    end

    it 'reports bootstrap=nil when no BootstrapState is passed (backwards compat)' do
      expect(status[:bootstrap]).to be_nil
    end

    it 'surfaces BootstrapState when provided' do
      require 'woods/mcp/bootstrap_state'
      state = Woods::MCP::BootstrapState.new
      state.mark(:hydrating)
      state.mark(:hydrated)

      s = Woods::MCP::Server.build_status(
        reader: reader, retriever: nil, index_dir: fixture_dir,
        bootstrap_state: state
      )
      expect(s[:bootstrap]).to include(status: :hydrated)
      expect(s[:bootstrap][:hydrated_at]).not_to be_nil
    end

    it 'surfaces degraded state with reason class + message' do
      require 'woods/mcp/bootstrap_state'
      require 'woods/mcp/errors'
      state = Woods::MCP::BootstrapState.new
      state.mark(:hydrating)
      reason = Woods::MCP::ProviderUnreachable.new(
        url: 'http://host.docker.internal:11434',
        reason: 'connection_refused'
      )
      state.mark(:degraded, reason: reason)

      s = Woods::MCP::Server.build_status(
        reader: reader, retriever: nil, index_dir: fixture_dir,
        bootstrap_state: state
      )
      expect(s[:bootstrap][:status]).to eq(:degraded)
      # BootstrapState.to_h formats reason as "<ClassName>: <message>"
      # — a single human-readable line that's grep-friendly for operators.
      expect(s[:bootstrap][:reason]).to include('Woods::MCP::ProviderUnreachable')
      expect(s[:bootstrap][:reason]).to include('connection_refused')
      expect(s[:bootstrap][:degraded_since]).not_to be_nil
    end
  end

  describe 'staleness gate (index.git_sha_matches_head)' do
    # Regression — the manifest captures git_sha / gemfile_lock_sha / schema_sha
    # at extraction time, but historic build_status never compared them against
    # the live working tree. A developer who commits 40 changes and restarts the
    # MCP without re-running woods:embed got pre-change answers silently. The
    # gate now surfaces git_sha_matches_head + head_git_sha so agents can branch
    # on staleness even though the server doesn't hard-refuse.
    let(:manifest_sha) { 'a' * 40 }
    let(:head_sha) { 'b' * 40 }

    def stub_git_head(head:, status_ok: true)
      process_status = instance_double(Process::Status, success?: status_ok)
      allow(Open3).to receive(:capture2e).with('git', '-C', anything, 'rev-parse', 'HEAD')
                                         .and_return(["#{head}\n", process_status])
    end

    it 'reports git_sha_matches_head=true when manifest.git_sha matches HEAD' do
      stub_git_head(head: manifest_sha)
      reader = double('reader', manifest: { 'git_sha' => manifest_sha, 'extracted_at' => nil, 'counts' => {} })

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: '/tmp')

      expect(status[:index][:git_sha]).to eq(manifest_sha)
      expect(status[:index][:head_git_sha]).to eq(manifest_sha)
      expect(status[:index][:git_sha_matches_head]).to be(true)
    end

    it 'reports git_sha_matches_head=false when HEAD has moved past manifest.git_sha' do
      stub_git_head(head: head_sha)
      reader = double('reader', manifest: { 'git_sha' => manifest_sha, 'extracted_at' => nil, 'counts' => {} })

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: '/tmp')

      expect(status[:index][:git_sha_matches_head]).to be(false)
      expect(status[:index][:head_git_sha]).to eq(head_sha)
    end

    it 'omits the comparison keys when index_dir is not a git repo' do
      stub_git_head(head: '', status_ok: false)
      reader = double('reader', manifest: { 'git_sha' => manifest_sha, 'extracted_at' => nil, 'counts' => {} })

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: '/tmp')

      expect(status[:index]).not_to have_key(:git_sha_matches_head)
      expect(status[:index]).not_to have_key(:head_git_sha)
    end

    it 'omits the comparison keys when manifest has no git_sha' do
      reader = double('reader', manifest: { 'extracted_at' => nil, 'counts' => {} })

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: '/tmp')

      expect(status[:index]).not_to have_key(:git_sha_matches_head)
    end

    it 'omits the comparison keys when index_dir does not exist (reader survived but dir gone)' do
      reader = double('reader', manifest: { 'git_sha' => manifest_sha, 'extracted_at' => nil, 'counts' => {} })

      status = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: '/nonexistent/path/xyz')

      expect(status[:index]).not_to have_key(:git_sha_matches_head)
    end
  end

  describe 'features drawn from ResolvedConfig' do
    # Regression — historic build_status read config.embedding_model (which
    # defaults to "text-embedding-3-small" in lib/woods.rb) regardless of the
    # provider actually hydrated from woods.json. Operators saw status claim
    # `embedding_model: "text-embedding-3-small"` alongside
    # `embedding_provider: "ollama"` and rightfully distrusted every field.
    let(:resolved) do
      require 'woods/resolved_config'
      Woods::ResolvedConfig.new(
        schema_version: 1,
        gem_version: '1.0.0',
        created_at: Time.now.utc,
        embedding_provider: {
          class: 'Woods::Embedding::Provider::Ollama',
          model: 'nomic-embed-text',
          dimension: 768,
          host: 'http://127.0.0.1:11434'
        },
        stores: { vector_store: :in_memory, metadata_store: :in_memory, graph_store: :in_memory }
      )
    end

    let(:state_with_resolved) do
      require 'woods/mcp/bootstrap_state'
      state = Woods::MCP::BootstrapState.new
      state.resolved_config = resolved
      state.mark(:hydrated)
      state
    end

    it 'reports embedding_model from resolved_config, not Woods.configuration default' do
      s = Woods::MCP::Server.build_status(
        reader: reader, retriever: nil, index_dir: fixture_dir,
        bootstrap_state: state_with_resolved
      )
      expect(s[:features][:embedding_model]).to eq('nomic-embed-text')
    end

    it 'reports embedding_provider as the short symbol form (:ollama, :openai)' do
      s = Woods::MCP::Server.build_status(
        reader: reader, retriever: nil, index_dir: fixture_dir,
        bootstrap_state: state_with_resolved
      )
      expect(s[:features][:embedding_provider]).to eq('ollama')
    end

    it 'reports vector_store from resolved_config.stores' do
      s = Woods::MCP::Server.build_status(
        reader: reader, retriever: nil, index_dir: fixture_dir,
        bootstrap_state: state_with_resolved
      )
      expect(s[:features][:vector_store]).to eq('in_memory')
    end

    it 'falls back to Woods.configuration when resolved_config is absent' do
      # Other specs in the suite may mutate or nil-out Woods.configuration —
      # pin a fresh one so the assertion doesn't depend on ordering.
      original_config = Woods.configuration
      Woods.configuration = Woods::Configuration.new
      begin
        s = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: fixture_dir)
        expect(s[:features][:embedding_model]).to eq('text-embedding-3-small')
      ensure
        Woods.configuration = original_config
      end
    end
  end

  describe 'missing-manifest resilience' do
    it 'returns ready=false and empty index metadata when manifest is unreadable' do
      broken_reader = Class.new do
        def manifest
          raise StandardError, 'boom'
        end
      end.new

      status = Woods::MCP::Server.build_status(reader: broken_reader, retriever: nil, index_dir: '/nope')
      expect(status[:ready]).to be_falsey
      expect(status[:index][:extracted_at]).to be_nil
      expect(status[:index][:counts]).to eq({})
    end
  end
end
