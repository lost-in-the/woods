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
        :notion_configured, :console_mcp_enabled
      )
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
