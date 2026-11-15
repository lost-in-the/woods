# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Console MCP deprecation notices' do
  let(:root) { File.expand_path('..', __dir__) }

  def read(path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  it 'opens docs/CONSOLE_MCP_SETUP.md with the deprecation, the removal release and what to use instead' do
    head = read('docs/CONSOLE_MCP_SETUP.md').lines.first(14).join

    expect(head).to match(/\*\*Deprecated\.\*\*/)
    expect(head).to include('Woods 3.0', 'Index Server', 'bin/rails runner')
  end

  %w[README.md docs/README.md SECURITY.md CLAUDE.md docs/MCP_SERVERS.md
     plugin/skills/woods-mcp-config/SKILL.md plugin/skills/woods-setup/SKILL.md].each do |path|
    it "marks the Console deprecated in #{path}, naming the removal release" do
      expect(read(path)).to match(/Console[^\n]*deprecated[^\n]*3\.0|deprecated[^\n]*Console[^\n]*3\.0/i)
    end
  end

  it 'gives the Console guide a "What to use instead" section for other pages to link to' do
    expect(read('docs/CONSOLE_MCP_SETUP.md')).to match(/^## What to use instead$/)
  end

  %w[docs/AGENT_SETUP.md docs/GETTING_STARTED.md docs/INTERNALS.md docs/MCP_SERVERS.md docs/DOCKER_SETUP.md
     docs/FAQ.md docs/README.md README.md].each do |path|
    it "limits the Console to existing setups in #{path} and links the alternatives" do
      text = read(path)

      expect(text).to include('Existing setups keep working; new setups should not enable it.')
      expect(text).to match(%r{CONSOLE_MCP_SETUP\.md#what-to-use-instead})
    end
  end

  it 'marks the Console section of the install template deprecated and tells new setups to leave it off' do
    section = read('lib/generators/woods/templates/woods.rb.tt')[/# ── Console MCP.*?(?=# ── )/m]

    expect(section).to include('DEPRECATED', 'Woods 3.0', 'New setups')
    expect(section).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end
end
