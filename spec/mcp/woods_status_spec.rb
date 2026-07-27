# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/server'
require 'woods/mcp/index_reader'
require 'woods/generation'
require 'woods/watch/status'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'woods_status tool' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:reader) { Woods::MCP::IndexReader.new(fixture_dir) }

  describe 'Woods::MCP::Server.build_status' do
    subject(:status) { Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: fixture_dir) }

    it 'reports server identity with the current gem version' do
      expect(status[:server]).to include(name: 'woods', version: Woods::VERSION, index_dir: fixture_dir.to_s)
    end

    it 'embeds an update sub-hash reporting the installed version (no update by default)' do
      # spec_helper stubs the network fetch to nil, so a hermetic run reports no update.
      expect(status[:server][:update]).to eq(
        current_version: Woods::VERSION,
        latest_version: nil,
        update_available: false
      )
    end

    it 'reports update_available=true when a newer version is published' do
      allow(Woods::UpdateCheck).to receive(:fetch_latest_version).and_return('999.0.0')

      s = Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: fixture_dir)
      expect(s[:server][:update]).to include(
        current_version: Woods::VERSION,
        latest_version: '999.0.0',
        update_available: true
      )
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

  # #164 phase 3: an agent needs to distinguish "the index is current",
  # "something is maintaining it but currently can't", and "nothing is
  # maintaining it" — none of which the manifest timestamp can express.
  describe 'freshness contract' do
    let(:index_dir) { Dir.mktmpdir('woods_status_freshness') }
    let(:reader) { double('reader', manifest: { 'extracted_at' => nil, 'counts' => {} }) }

    before do
      # Keep the git probes hermetic; this context is about the other fields.
      # resolve_head_sha still folds stderr in (capture2e); the working-tree
      # probe deliberately does not (capture3) — see below.
      allow(Open3).to receive(:capture2e).and_return(['', instance_double(Process::Status, success?: false)])
      allow(Open3).to receive(:capture3).and_return(['', '', instance_double(Process::Status, success?: false)])
    end

    after { FileUtils.rm_rf(index_dir) }

    def status_for
      Woods::MCP::Server.build_status(reader: reader, retriever: nil, index_dir: index_dir)
    end

    describe 'index.generation' do
      it 'reports the published generation, when it moved, and what moved it' do
        Woods::Generation.new(output_dir: index_dir).bump!(reason: 'incremental')

        expect(status_for[:index]).to include(generation: 1, generation_reason: 'incremental')
        expect(status_for[:index][:generation_updated_at]).not_to be_nil
      end

      it 'reports a nil generation for an index that has never published one' do
        expect(status_for[:index][:generation]).to be_nil
      end
    end

    describe 'index.working_tree_*' do
      # git_sha_matches_head only sees committed HEAD. Forty uncommitted edits
      # leave it reporting a match while every answer describes the tree
      # before those edits.
      def stub_porcelain(stdout, stderr = '', success: true)
        allow(Open3).to receive(:capture3).with('git', '-C', anything, 'status', '--porcelain')
                                          .and_return([stdout, stderr,
                                                       instance_double(Process::Status, success?: success)])
      end

      it 'reports a clean working tree' do
        stub_porcelain('')

        expect(status_for[:index][:working_tree_dirty]).to be(false)
      end

      it 'reports a dirty working tree with a fingerprint of the change set' do
        stub_porcelain(" M app/models/post.rb\n")

        expect(status_for[:index][:working_tree_dirty]).to be(true)
        expect(status_for[:index][:working_tree_fingerprint]).to match(/\A[0-9a-f]{16}\z/)
      end

      # Folding stderr into stdout made any warning git emits on a *successful*
      # run part of the porcelain output — so a clean tree read as dirty, and the
      # fingerprint tracked the warning rather than the code.
      it 'stays clean when git warns on stderr but succeeds' do
        stub_porcelain('', "warning: unable to rmdir 'vendor/x': Directory not empty\n")

        expect(status_for[:index][:working_tree_dirty]).to be(false)
      end

      it 'omits the fields entirely when git cannot answer' do
        expect(status_for[:index]).not_to have_key(:working_tree_dirty)
      end
    end

    describe 'watch' do
      it 'reports absent when no daemon has ever run' do
        expect(status_for[:watch]).to eq(state: 'absent')
      end

      it 'reports a running daemon' do
        Woods::Watch::Status.new(output_dir: index_dir)
                            .write(state: :running, generation: 7, last_action: 'incremental')

        expect(status_for[:watch]).to include(state: 'running', generation: 7, last_action: 'incremental')
      end

      # The state that matters: alive, but the index is frozen and the reason
      # says why. Without this an agent cannot tell stale from wrong.
      it 'reports a degraded daemon with its reason' do
        Woods::Watch::Status.new(output_dir: index_dir)
                            .write(state: :degraded, generation: 7,
                                   reason: 'SyntaxError: unexpected end-of-input')

        expect(status_for[:watch]).to include(state: 'degraded', generation: 7)
        expect(status_for[:watch][:reason]).to include('SyntaxError')
      end

      it 'reports absent rather than raising on an unreadable status file' do
        File.write(File.join(index_dir, Woods::Watch::Status::FILENAME), 'not json')

        expect(status_for[:watch]).to eq(state: 'absent')
      end
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

    def stub_git_head(head:, status_ok: true, porcelain: '')
      process_status = instance_double(Process::Status, success?: status_ok)
      allow(Open3).to receive(:capture2e).with('git', '-C', anything, 'rev-parse', 'HEAD')
                                         .and_return(["#{head}\n", process_status])
      # build_status also asks for the working-tree state; without a stub the
      # real git runs against whatever /tmp happens to be.
      allow(Open3).to receive(:capture2e).with('git', '-C', anything, 'status', '--porcelain')
                                         .and_return([porcelain, process_status])
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
