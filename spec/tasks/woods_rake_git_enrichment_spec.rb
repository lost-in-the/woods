# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/rake_helpers'

RSpec.describe 'Git-enrichment summary in the extraction task output' do
  let(:published) do
    { 'version' => 1, 'state' => 'degraded', 'reason' => 'head_unresolvable', 'head_sha' => nil,
      'coverage' => { 'eligible_units' => 10, 'with_facts' => 4, 'history_unavailable' => 6,
                      'excluded' => { 'fileless' => 0, 'dependency_owned' => 0, 'source_missing' => 0 } },
      'capture' => { 'refreshed' => 0, 'retained' => 4 } }
  end

  it 'summarises the published manifest in one line' do
    Dir.mktmpdir('woods-git-summary') do |index|
      File.write(File.join(index, 'manifest.json'), JSON.generate('git_enrichment' => published))

      expect(Woods::RakeHelpers.woods_git_enrichment_summary(index))
        .to eq('Git enrichment: degraded, head_unresolvable (4 of 10 eligible units with facts; ' \
               '0 refreshed, 4 retained)')
    end
  end

  it 'says unknown for an index published before the summary existed' do
    Dir.mktmpdir('woods-git-summary') do |index|
      File.write(File.join(index, 'manifest.json'), JSON.generate('counts' => {}))

      expect(Woods::RakeHelpers.woods_git_enrichment_summary(index))
        .to eq('Git enrichment: unknown (summary_missing)')
    end
  end

  it 'says unknown when there is no manifest to read' do
    Dir.mktmpdir('woods-git-summary') do |index|
      expect(Woods::RakeHelpers.woods_git_enrichment_summary(index))
        .to eq('Git enrichment: unknown (summary_missing)')
    end
  end
end
