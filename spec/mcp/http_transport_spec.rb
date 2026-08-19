# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCP HTTP Transport' do
  let(:executable_path) { File.expand_path('../../exe/woods-mcp-http', __dir__) }

  describe 'executable' do
    it 'exists' do
      expect(File.exist?(executable_path)).to be true
    end

    it 'is executable' do
      expect(File.executable?(executable_path)).to be true
    end

    it 'has correct shebang' do
      first_line = File.readlines(executable_path).first
      expect(first_line.strip).to eq('#!/usr/bin/env ruby')
    end

    it 'has frozen string literal pragma' do
      second_line = File.readlines(executable_path)[1]
      expect(second_line.strip).to eq('# frozen_string_literal: true')
    end
  end

  describe 'StreamableHTTPTransport' do
    it 'is defined in the MCP gem' do
      require 'mcp'
      expect(defined?(MCP::Server::Transports::StreamableHTTPTransport)).to be_truthy
    end

    it 'accepts the stateless mode introduced by MCP 2026-07-28' do
      require 'mcp'
      server = MCP::Server.new(name: 'test', version: '1.0')
      expect { MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true) }
        .not_to raise_error
    end
  end

  # MCP 2026-07-28 (SEP-2567) removes protocol-level sessions. For this server
  # the session was never carrying anything — the index is on disk and
  # IndexReader self-refreshes — but it did tie every client to one process, so
  # a restart invalidated every session and forced a re-initialize.
  describe 'statelessness' do
    # Explicit UTF-8: the suite runs under LANG=C, so a bare File.read tags the
    # bytes US-ASCII and any `match` against a comment containing an em dash
    # raises rather than failing. Ruby source is UTF-8 by definition, so naming
    # the encoding here is correct, not a workaround.
    let(:source) { File.read(executable_path, encoding: Encoding::UTF_8) }

    it 'constructs the transport in stateless mode' do
      expect(source).to match(/StreamableHTTPTransport\.new\(server, stateless: stateless\)/)
    end

    it 'defaults to stateless when the env var is unset' do
      expect(source).to match(/WOODS_MCP_HTTP_STATELESS', '1'/)
    end

    it 'keeps a documented escape hatch back to session mode' do
      expect(source).to include('WOODS_MCP_HTTP_STATELESS=0')
    end

    it 'ignores stale session ids before the SDK transport sees them' do
      expect(source).to include("env.delete('HTTP_MCP_SESSION_ID') if stateless")
    end
  end

  describe 'the stateless escape hatch parsing' do
    # Mirrors the expression in exe/woods-mcp-http. Extracted here because the
    # executable runs a Rack server on load and cannot be required in-process.
    def stateless?(value)
      !%w[0 false no].include?((value || '1').strip.downcase)
    end

    it 'is on by default' do
      expect(stateless?(nil)).to be true
    end

    it 'accepts the documented off switches, case-insensitively and whitespace-tolerantly' do
      off = ['0', 'false', 'no', 'FALSE', '  No  ', "0\n"]
      expect(off.map { |v| stateless?(v) }).to all(be false)
    end

    it 'stays on for any other value' do
      expect(stateless?('1')).to be true
      expect(stateless?('yes')).to be true
    end
  end

  describe 'gemspec' do
    let(:gemspec_path) { File.expand_path('../../woods.gemspec', __dir__) }

    it 'includes the HTTP executable in the executables list' do
      content = File.read(gemspec_path)
      expect(content).to include('woods-mcp-http')
    end

    it 'declares rackup as a runtime dependency' do
      spec = Gem::Specification.load(gemspec_path)
      rackup = spec.dependencies.find { |dependency| dependency.name == 'rackup' }

      expect(rackup).not_to be_nil
      expect(rackup.type).to eq(:runtime)
    end
  end
end
