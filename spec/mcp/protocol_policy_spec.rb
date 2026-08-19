# frozen_string_literal: true

require 'spec_helper'
require 'mcp'
require 'woods/mcp/protocol_policy'

RSpec.describe Woods::MCP::ProtocolPolicy do
  around do |example|
    original = ENV.fetch(described_class::TTL_ENV_KEY, nil)
    example.run
  ensure
    ENV[described_class::TTL_ENV_KEY] = original
  end

  describe '.ttl_ms' do
    it 'defaults when the env var is unset' do
      ENV.delete(described_class::TTL_ENV_KEY)
      expect(described_class.ttl_ms).to eq(described_class::DEFAULT_TTL_MS)
    end

    it 'honours a valid override' do
      ENV[described_class::TTL_ENV_KEY] = '60000'
      expect(described_class.ttl_ms).to eq(60_000)
    end

    it 'honours an explicit zero (caching disabled)' do
      ENV[described_class::TTL_ENV_KEY] = '0'
      expect(described_class.ttl_ms).to eq(0)
    end

    # A cache hint is not worth an outage: the server is mid-conversation with
    # an agent, and refusing to boot over a typo'd env var trades a mild
    # performance regression for a total one.
    it 'falls back to the default rather than raising on a malformed value' do
      ENV[described_class::TTL_ENV_KEY] = 'not-a-number'
      expect(described_class.ttl_ms).to eq(described_class::DEFAULT_TTL_MS)
    end

    it 'falls back to the default on a negative value' do
      ENV[described_class::TTL_ENV_KEY] = '-1'
      expect(described_class.ttl_ms).to eq(described_class::DEFAULT_TTL_MS)
    end

    it 'falls back to the default on an empty value' do
      ENV[described_class::TTL_ENV_KEY] = '   '
      expect(described_class.ttl_ms).to eq(described_class::DEFAULT_TTL_MS)
    end
  end

  describe '.cache_hints' do
    # The security-relevant half. The SDK's fallback when only ttl_ms is set is
    # cacheScope "public", which would let a shared proxy in front of
    # woods-mcp-http re-serve one user's source code to another.
    it 'always scopes caching to the requesting client' do
      expect(described_class.cache_hints[:cache_scope]).to eq('private')
    end

    it 'is accepted by MCP::Server as keyword arguments' do
      server = MCP::Server.new(name: 'test', version: '1.0', **described_class.cache_hints)
      expect(server.cache_scope).to eq('private')
      expect(server.ttl_ms).to eq(described_class.ttl_ms)
    end
  end

  describe '.sort_tools!' do
    def build_server_with(names)
      server = MCP::Server.new(name: 'test', version: '1.0')
      names.each do |name|
        server.define_tool(name: name, description: name, input_schema: { type: 'object', properties: {} }) do |**|
          MCP::Tool::Response.new([{ type: 'text', text: 'ok' }])
        end
      end
      server
    end

    it 'orders tools by name regardless of registration order' do
      server = build_server_with(%w[zebra alpha monkey])
      described_class.sort_tools!(server)
      expect(server.instance_variable_get(:@tools).keys).to eq(%w[alpha monkey zebra])
    end

    it 'returns the server so it can close a builder method' do
      server = build_server_with(%w[a])
      expect(described_class.sort_tools!(server)).to be(server)
    end

    # The property that matters: two hosts with different optional integrations
    # wired must advertise the shared tools in the same order, or every agent
    # turn re-sends a reordered tool block and misses the prompt cache.
    it 'produces the same relative order for a subset as for a superset' do
      full = build_server_with(%w[search lookup notion_sync pipeline_extract reload])
      lean = build_server_with(%w[reload search lookup])
      described_class.sort_tools!(full)
      described_class.sort_tools!(lean)

      lean_names = lean.instance_variable_get(:@tools).keys
      full_names = full.instance_variable_get(:@tools).keys
      expect(full_names & lean_names).to eq(lean_names)
    end

    # The reach into @tools is contained; if a future SDK changes the internal
    # shape this must degrade to "unsorted", never raise on a live server.
    it 'no-ops when the internal tool collection is not a Hash' do
      server = build_server_with(%w[a])
      server.instance_variable_set(:@tools, nil)
      expect { described_class.sort_tools!(server) }.not_to raise_error
    end
  end
end
