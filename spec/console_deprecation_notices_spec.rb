# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Console removal notices' do
  let(:root) { File.expand_path('..', __dir__) }

  def read(path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  let(:current_pages) do
    %w[README.md SECURITY.md CLAUDE.md AGENTS.md CONTRIBUTING.md lib/generators/woods/templates/woods.rb.tt] +
      Dir.chdir(root) { Dir['docs/*.md'] + Dir['plugin/skills/*/SKILL.md'] }
  end

  it 'gives the removal its own page: the release, why, and how to clean up' do
    require 'woods/console'
    page = read('docs/CONSOLE_REMOVED.md')

    expect(page).to include('Woods 2.2.0', Woods::Console::REMOVED_MESSAGE)
    expect(page.scan(/^## .*$/)).to eq(['## Why', '## Cleaning up after an upgrade'])
  end

  it 'suggests no replacement for the Console on any current page or skill' do
    suggesting = (current_pages + %w[docs/CONSOLE_REMOVED.md]).uniq.select do |path|
      read(path).match?(/what-to-use-instead|database MCP|scrubbed replica/i)
    end

    expect(suggesting).to eq([])
  end

  it 'keeps the Console guide as a pointer to the removal for the 2.1.x and 1.6.x lines' do
    head = read('docs/CONSOLE_MCP_SETUP.md').lines.first(8).join

    expect(head).to include('Removed in Woods 2.2.0', 'CONSOLE_REMOVED.md', '2.1.x', '1.6.x')
  end

  %w[docs/README.md SECURITY.md CLAUDE.md docs/MCP_SERVERS.md].each do |path|
    it "names the removal release in #{path}" do
      expect(read(path)).to match(/Console[^\n]*removed[^\n]*2\.2\.0/i)
    end
  end

  it 'names the removal in README.md, which names versions only inside release-state fences' do
    expect(read('README.md')).to match(/Console[^\n]*removed/).and include('docs/CONSOLE_REMOVED.md')
  end

  it 'leaves no current page or skill calling the Console deprecated' do
    deprecated = current_pages.select do |path|
      read(path).match?(/Console[^\n]{0,80}deprecated|deprecated[^\n]{0,80}Console/i)
    end

    expect(deprecated).to eq([])
  end
end
