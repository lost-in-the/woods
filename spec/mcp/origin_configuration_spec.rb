# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/origin_policy'
require 'open3'

RSpec.describe 'Origin configuration diagnostics' do
  before { Woods.configuration = nil }
  after { Woods.configuration = nil }

  %w[example.test https://example.test/path * null https://one.test,https://two.test].each do |entry|
    it "names the malformed configured entry #{entry.inspect}" do
      expect { Woods::MCP::OriginPolicy.new(allowed_origins: [entry]) }
        .to raise_error(ArgumentError, /#{Regexp.escape(entry)}/)
    end
  end

  it 'prints a bounded executable boot diagnostic instead of a backtrace' do
    executable = File.expand_path('../../exe/woods-mcp-http', __dir__)
    _stdout, stderr, status = Open3.capture3(
      { 'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => 'invalid-entry' },
      RbConfig.ruby, '-rbundler/setup', executable, '/unused-index-for-invalid-configuration'
    )
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include('[woods-mcp-http] ConfigurationError: Invalid MCP allowed origin "invalid-entry"')
    expect(stderr.lines.size).to eq(1)
  end
end
