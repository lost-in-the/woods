# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/origin_policy'
require 'open3'

RSpec.describe 'HTTP origin encoding diagnostics' do
  let(:invalid_origin) { "https://example.test/#{255.chr.force_encoding(Encoding::UTF_8)}" }

  it 'names an invalidly encoded configured entry without leaking an encoding exception' do
    expect { Woods::MCP::OriginPolicy.new(allowed_origins: [invalid_origin]) }
      .to raise_error(ArgumentError, /Invalid MCP allowed origin.*example\.test/)
  end

  it 'refuses a binary entry with non-ASCII bytes through the same configuration contract' do
    expect { Woods::MCP::OriginPolicy.new(allowed_origins: [invalid_origin.b]) }
      .to raise_error(ArgumentError, /Invalid MCP allowed origin.*example\.test/)
  end

  %w[C C.UTF-8].each do |locale|
    it "prints one configuration diagnostic before resolving the index or binding HTTP under #{locale}" do
      executable = File.expand_path('../../exe/woods-mcp-http', __dir__)
      stdout, stderr, status = Open3.capture3(
        { 'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => invalid_origin, 'LANG' => locale, 'LC_ALL' => locale },
        RbConfig.ruby, '-rbundler/setup', executable, '/unused-index-for-invalid-configuration'
      )

      expect(status.exitstatus).to eq(2)
      expect(stdout).to be_empty
      expect(stderr.lines.size).to eq(1)
      expect(stderr).to include(
        '[woods-mcp-http] ConfigurationError:', 'WOODS_MCP_HTTP_ALLOWED_ORIGINS', 'example.test'
      )
    end
  end
end
