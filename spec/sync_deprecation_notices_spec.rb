# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Notion and Unblocked deprecation notices' do
  let(:root) { File.expand_path('..', __dir__) }

  {
    'docs/NOTION_INTEGRATION.md' => 'Notion',
    'docs/UNBLOCKED_INTEGRATION.md' => 'Unblocked',
    '.claude/skills/unblocked-sync/SKILL.md' => 'Unblocked'
  }.each do |path, vendor|
    it "marks #{path} deprecated near the top and points at the Markdown export" do
      head = File.read(File.join(root, path), encoding: Encoding::UTF_8).lines.first(14).join
      expect(head).to match(/deprecated/i)
      expect(head).to include(vendor)
      expect(head).to include('woods:markdown')
    end
  end
end
