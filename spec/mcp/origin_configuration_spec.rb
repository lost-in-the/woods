# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/mcp/origin_policy'
require 'woods/railtie_support'
require 'woods/console/rack_middleware'
require 'open3'

RSpec.describe 'Origin configuration diagnostics' do
  before { Woods.configuration = nil }
  after { Woods.configuration = nil }

  %w[example.test https://example.test/path * null https://one.test,https://two.test].each do |entry|
    it "names the malformed configured entry #{entry.inspect}" do
      expect { Woods::MCP::OriginPolicy.new(allowed_origins: [entry]) }
        .to raise_error(ArgumentError, /#{Regexp.escape(entry)}/)
    end

    it "refuses malformed HTTP Console configuration at boot for #{entry.inspect}" do
      Woods.configure do |config|
        config.console_mcp_enabled = true
        config.console_mcp_http_enabled = true
        config.console_mcp_token = 'test-token-' * 4
        config.console_mcp_allowed_origins = [entry]
      end
      expect { Woods::RailtieSupport.verify_console_configuration!(production: false) }
        .to raise_error(Woods::ConfigurationError, /#{Regexp.escape(entry)}/)
    end
  end

  it 'leaves stdio-only Console unaffected by unused HTTP origin configuration' do
    Woods.configure do |config|
      config.console_mcp_enabled = true
      config.console_mcp_http_enabled = false
      config.console_mcp_allowed_origins = ['malformed']
    end
    expect { Woods::RailtieSupport.verify_console_configuration!(production: false) }.not_to raise_error
  end

  it 'refuses a misconfigured enabled manual mount during construction' do
    Woods.configure do |config|
      config.console_mcp_enabled = true
      config.console_mcp_token = 'test-token-' * 4
      config.console_mcp_allowed_origins = ['invalid-entry']
    end
    expect { Woods::Console::RackMiddleware.new(->(_env) { [200, {}, []] }) }
      .to raise_error(ArgumentError, /invalid-entry/)
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
