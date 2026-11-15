# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Console MCP deprecation notices' do
  let(:root) { File.expand_path('..', __dir__) }

  def read(path)
    File.read(File.join(root, path), encoding: Encoding::UTF_8)
  end

  %w[plugin/skills/woods-mcp-config/SKILL.md plugin/skills/woods-setup/SKILL.md].each do |path|
    it "marks the Console deprecated in #{path}, naming the removal release" do
      expect(read(path)).to match(/Console[^\n]*deprecated[^\n]*3\.0|deprecated[^\n]*Console[^\n]*3\.0/i)
    end
  end

  it 'marks the Console section of the install template deprecated and tells new setups to leave it off' do
    section = read('lib/generators/woods/templates/woods.rb.tt')[/# ── Console MCP.*?(?=# ── )/m]

    expect(section).to include('DEPRECATED', 'Woods 3.0', 'New setups')
    expect(section).to match(/^\s*#\s*config\.console_mcp_enabled\s*=\s*false/)
  end
end
