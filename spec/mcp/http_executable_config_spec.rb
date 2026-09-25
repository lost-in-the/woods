# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'HTTP executable origin configuration' do
  it 'refuses malformed entries before index bootstrap with a bounded single-line diagnostic' do
    root = File.expand_path('../..', __dir__)
    invalid = "https://example.invalid/\n#{'x' * 400}"
    out, err, status = Open3.capture3(
      { 'WOODS_MCP_HTTP_ALLOWED_ORIGINS' => invalid }, RbConfig.ruby,
      File.join(root, 'exe/woods-mcp-http'), '/unused-synthetic-index', chdir: root
    )

    expect(status.exitstatus).to eq(2)
    expect(out).to be_empty
    expect(err.lines.length).to eq(1)
    expect(err).to include('ConfigurationError', 'Invalid MCP allowed origin', '\\n')
    expect(err.bytesize).to be < 450
    expect(err).not_to include('BootstrapError', '/unused-synthetic-index')
  end
end
