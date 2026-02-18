# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCP HTTP Transport' do
  let(:executable_path) { File.expand_path('../../exe/codebase-index-mcp-http', __dir__) }

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
  end

  describe 'gemspec' do
    let(:gemspec_path) { File.expand_path('../../codebase_index.gemspec', __dir__) }

    it 'includes the HTTP executable in the executables list' do
      content = File.read(gemspec_path)
      expect(content).to include('codebase-index-mcp-http')
    end
  end
end
