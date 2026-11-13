# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require_relative '../../script/release_profile'

# Pull requests run the Ruby and Rails lines that still receive security
# releases, each at its newest patch (the gemfiles pin `~> X.Y.0` with no
# checked-in lockfile, and setup-ruby resolves the newest patch of a minor).
# End-of-life lines run on main and version tags, which keep the full matrix
# and the full incremental-equivalence depth. Every row still reports a
# result on a pull request, so a required check never waits on a row that
# was not scheduled; the `not-run` check lists the rows a pull request skips.
# The `full-matrix` label runs every row on a pull request.
#
# Security support, as of 2026-10-28 (rubyonrails.org/maintenance,
# ruby-lang.org/en/downloads/branches): Rails 8.1 (to 2027-10-10) and 8.0
# (to 2026-11-07); Ruby 4.0, 3.4 and 3.3 (to 2027-03-31). When a line
# reaches end of life, set its rows to `pr: false` here and in ci.yml.
RSpec.describe 'CI pull request tier' do
  let(:jobs) do
    YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true).fetch('jobs')
  end
  # One condition decides whether a row runs: a pull request without the
  # `full-matrix` label skips the `pr: false` rows.
  let(:condition) do
    "github.event_name != 'pull_request' || matrix.pr || " \
      "contains(github.event.pull_request.labels.*.name, 'full-matrix')"
  end
  let(:active) { "${{ #{condition} }}" }
  let(:names) do
    {
      'test' => 'Unit specs (Ruby ${{ matrix.ruby-version }})',
      'test-required' => 'Unit specs (Ruby ${{ matrix.ruby-version }})',
      'rails-matrix' => 'Booted extraction (Ruby ${{ matrix.ruby }} / Rails ${{ matrix.rails }})',
      'rails-required' => 'Booted extraction (Ruby ${{ matrix.ruby }} / Rails ${{ matrix.rails }})'
    }
  end

  def rendered(id, row)
    jobs.fetch(id).fetch('name').gsub(/\$\{\{ matrix\.([\w-]+) \}\}/) { row.fetch(Regexp.last_match(1)) }
  end

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

  # A change the end-of-life rows guard needs them before merge. A manual
  # dispatch is not a pull_request event, so every row is active on it.
  it 'can run every row on any branch on request' do
    workflow = YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true)
    triggers = workflow['on'] || workflow[true]

    expect(triggers).to have_key('workflow_dispatch')
    expect(active).to start_with("${{ github.event_name != 'pull_request'")
  end

  # A run with the `full-matrix` label starts as soon as the label is added.
  # A separate workflow dispatches CI for that one label, so other label
  # events neither start nor cancel a CI run.
  it 'dispatches the full matrix when the full-matrix label is added' do
    workflow = YAML.safe_load_file(File.expand_path('../../.github/workflows/full-matrix.yml', __dir__))
    triggers = workflow['on'] || workflow[true]
    ci = YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true)
    ci_triggers = ci['on'] || ci[true]

    expect(triggers).to eq('pull_request' => { 'types' => ['labeled'] })
    expect(ci_triggers.fetch('pull_request')).not_to have_key('types')
    expect(workflow.fetch('jobs').size).to eq(1)
    job = workflow.fetch('jobs').values.first
    expect(job.fetch('if')).to include("github.event.label.name == 'full-matrix'",
                                       'github.event.pull_request.head.repo.full_name == github.repository')
    expect(job.fetch('permissions')).to eq('actions' => 'write')
    expect(job.fetch('steps').map { |step| step.fetch('run') }.join).to include('gh workflow run ci.yml')
  end

  # Rulesets and the release validator require these names on every event, so
  # a skipped row keeps its name; the `not-run` check says what was skipped.
  it 'names every matrix row the same on every event' do
    names.each { |id, name| expect(jobs.fetch(id).fetch('name')).to eq(name) }
    rendered_names = names.keys.flat_map { |id| rows(id).map { |row| rendered(id, row) } }

    expect(rendered_names).to contain_exactly(
      *%w[3.0 3.1 3.2 3.3 3.4 4.0].map { |ruby| "Unit specs (Ruby #{ruby})" },
      *[%w[3.0 6.0], %w[3.0 6.1], %w[3.1 7.0], %w[3.2 7.1], %w[3.3 7.2], %w[3.3 8.0], %w[3.4 8.1], %w[4.0 8.0],
        %w[4.0 8.1]].map { |ruby, rails| "Booted extraction (Ruby #{ruby} / Rails #{rails})" }
    )
    expect(ReleaseProfile::MAINTENANCE_JOBS.grep(/\A(Unit specs|Booted extraction) /) - rendered_names).to be_empty
  end

  it 'lists exactly the rows a pull request skips, only when it skips them' do
    job = jobs.fetch('not-run')
    skipped = names.keys.flat_map { |id| rows(id).reject { |row| row.fetch('pr') }.map { |row| [id, row] } }
    unit_rubies = skipped.select { |id, _| id.start_with?('test') }.map { |_, row| row.fetch('ruby-version') }
    rails = skipped.reject { |id, _| id.start_with?('test') }.map { |_, row| row.fetch('rails') }

    expect(job.fetch('if')).to eq("github.event_name == 'pull_request' && " \
                                  "!contains(github.event.pull_request.labels.*.name, 'full-matrix')")
    expect(job).not_to have_key('needs')
    expect(job.fetch('name')).to eq("Not run on this PR: Ruby #{unit_rubies.min}-#{unit_rubies.max} units, " \
                                    "Rails #{rails.min}-#{rails.max} booted (label full-matrix to run)")
    named_range = ->(versions, all) { all.grep(versions.min..versions.max) }
    expect(named_range.call(unit_rubies, rows('test', 'test-required').map { |row| row.fetch('ruby-version') }))
      .to match_array(unit_rubies)
    expect(named_range.call(rails, rows('rails-matrix', 'rails-required').map { |row| row.fetch('rails') }))
      .to match_array(rails)
    step = job.fetch('steps').tap { |s| expect(s.size).to eq(1) }.first
    expect(step.dig('env', 'NOT_RUN').split(', ')).to eq(skipped.map { |id, row| rendered(id, row) })
    expect(step.fetch('run')).to include('>> "$GITHUB_STEP_SUMMARY"', 'echo "::notice::${message}"')
  end

  it 'gates the run on every other job through one CI gate check' do
    gate = jobs.fetch('ci-gate')

    expect(gate.fetch('name')).to eq('CI gate')
    expect(gate.fetch('if')).to eq('always()')
    expect(gate.fetch('needs')).to match_array(jobs.keys - ['ci-gate'])
    expect(gate.fetch('steps').tap { |s| expect(s.size).to eq(1) }.first.dig('env', 'FAILED'))
      .to eq("${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}")
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
