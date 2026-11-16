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
      expect(text).to match(/CONSOLE_MCP_SETUP\.md#what-to-use-instead/)
    end
  end

  it 'marks the Console section of the install template deprecated and tells new setups to leave it off' do
    section = read('lib/generators/woods/templates/woods.rb.tt')[/# ── Console MCP.*?(?=# ── )/m]

    expect(section).to include('DEPRECATED', 'Woods 3.0', 'New setups')
    expect(section).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end

  describe 'turning the Console off' do
    let(:guide) { read('docs/CONSOLE_MCP_SETUP.md') }
    let(:section) { guide[/^## Turning the Console off$.*?(?=^## )/m] }
    let(:skill) { read('plugin/skills/woods-console-disable/SKILL.md') }
    let(:disabled_line) do
      read('exe/woods-console')[/unless Woods\.configuration\.console_mcp_enabled\n\s*warn (.*?)\n\s*exit 1/m, 1]
        .scan(/'([^']*)'/).join
    end
    let(:deprecated_line) do
      require 'woods/console/deprecation_notice'
      "[woods] DEPRECATED: #{Woods::Console::DEPRECATION_MESSAGE}"
    end

    it 'has a section in the Console guide that names the skill' do
      expect(section).to include('woods-console-disable')
    end

    it 'quotes, in the guide and the skill, exactly the lines a disabled Console prints' do
      expect(disabled_line).to start_with('Woods Console MCP is disabled.')
      [section, skill].each { |text| expect(text).to include(disabled_line, deprecated_line) }
    end

    it 'covers every place the Console can be switched on or reached' do
      %w[console_mcp_enabled .mcp.json Woods::Console::RackMiddleware WOODS_CONSOLE_MCP_TOKEN
         WOODS_CONSOLE_CONFIG ~/.woods/console.yml woods:console woods-console-mcp].each do |place|
        expect([section, skill]).to all(include(place))
      end
    end

    it 'keeps the skill to its safety rules and the alternatives' do
      expect(skill).to include('Never delete a file.', 'Never print a token value.', 'Leave the Index Server alone.',
                               'Ask before every edit.', 'bin/rails runner', 'Woods 3.0',
                               'CONSOLE_MCP_SETUP.md#turning-the-console-off')
    end
  end

  describe 'plugin skill frontmatter' do
    Dir[File.expand_path('../plugin/skills/*/SKILL.md', __dir__)].each do |path|
      skill = File.basename(File.dirname(path))

      it "names #{skill} after its directory and gives it a description" do
        frontmatter = File.read(path, encoding: Encoding::UTF_8)[/\A---\n(.*?)\n---\n/m, 1]

        expect(frontmatter).to match(/^name: #{Regexp.escape(skill)}$/)
        expect(frontmatter).to match(/^description: \S/)
      end
    end
  end
end
