# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Notion and Unblocked deprecation notices' do
  let(:root) { File.expand_path('..', __dir__) }

  {
    'docs/NOTION_INTEGRATION.md' => 'Notion',
    'docs/UNBLOCKED_INTEGRATION.md' => 'Unblocked',
    '.claude/skills/unblocked-sync/SKILL.md' => 'Unblocked',
    'docs/OBSIDIAN_INTEGRATION.md' => 'Obsidian'
  }.each do |path, vendor|
    it "marks #{path} deprecated near the top and points at the Markdown export" do
      head = File.read(File.join(root, path), encoding: Encoding::UTF_8).lines.first(14).join
      expect(head).to match(/deprecated/i)
      expect(head).to include(vendor)
      expect(head).to include('woods:markdown')
      expect(head.split.join(' ')).to include('removed in Woods 3.0')
    end
  end

  it 'never promises a removal in a minor release' do
    paths = Dir.glob(%w[docs/*.md lib/**/*.rb lib/tasks/*.rake .claude/skills/**/*.md changelog/*.md], base: root)
    promising = paths.select do |path|
      File.read(File.join(root, path), encoding: Encoding::UTF_8).split.join(' ')
          .match?(/removed in the next minor release/i)
    end
    expect(promising).to be_empty
  end
end
