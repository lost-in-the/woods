# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Pull requests run the Ruby and Rails lines that still receive security
# releases, each at its newest patch (the gemfiles pin `~> X.Y.0` with no
# checked-in lockfile, and setup-ruby resolves the newest patch of a minor).
# End-of-life lines run on main and version tags, which keep the full matrix
# and the full incremental-equivalence depth. Every row still reports a
# result on a pull request, so a required check never waits on a row that
# was not scheduled.
#
# Security support, as of 2026-10-28 (rubyonrails.org/maintenance,
# ruby-lang.org/en/downloads/branches): Rails 8.1 (to 2027-10-10) and 8.0
# (to 2026-11-07); Ruby 4.0, 3.4 and 3.3 (to 2027-03-31). When a line
# reaches end of life, set its rows to `pr: false` here and in ci.yml.
RSpec.describe 'CI pull request tier' do
  let(:jobs) do
    YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true).fetch('jobs')
  end
  let(:active) { "${{ github.event_name != 'pull_request' || matrix.pr }}" }

  def rows(*ids)
    ids.flat_map { |id| jobs.fetch(id).dig('strategy', 'matrix', 'include') }
  end

  it 'runs the security-supported Ruby lines on pull requests' do
    pr_rubies = rows('test', 'test-required').select { |row| row.fetch('pr') }.map { |row| row.fetch('ruby-version') }

    expect(pr_rubies).to contain_exactly('3.3', '3.4', '4.0')
  end

  it 'runs the security-supported Rails lines on pull requests, plus the fixture-contract row' do
    pr_rows = rows('rails-matrix', 'rails-required').select { |row| row.fetch('pr') }

    expect(pr_rows.map { |row| row.fetch('rails') }).to contain_exactly('8.0', '8.0', '8.1', '8.1', '7.2')
  end

  it 'runs the incremental-equivalence harness at smoke depth on every pull request row' do
    rows('rails-matrix', 'rails-required').each do |row|
      expect(row).to include('pr_diff_ops' => '8', 'pr_diff_seeds' => '1')
    end
  end

  %w[test test-required rails-matrix rails-required].each do |id|
    it "gates every step of #{id} on whether its row runs for this event" do
      job = jobs.fetch(id)
      expect(job.fetch('env')).to include('WOODS_CI_ROW_ACTIVE' => active)

      notice, *work = job.fetch('steps')
      expect(notice.fetch('if')).to eq("env.WOODS_CI_ROW_ACTIVE != 'true'")
      work.each do |step|
        expect(step.fetch('if')).to start_with("${{ env.WOODS_CI_ROW_ACTIVE == 'true'"), step.inspect
      end
    end
  end
end
