# frozen_string_literal: true

require 'spec_helper'
require 'woods/full_run_reason'

RSpec.describe Woods::FullRunReason do
  def reason(paths, range:, diff: ->(_range) { raise 'git consulted' })
    described_class.new(paths: paths, range: range, diff: diff).lines
  end

  it 'says nothing when no path forced the run' do
    expect(reason([], range: 'HEAD~1')).to eq([])
  end

  it 'attributes every path of a two-revision CI range to that range without another diff' do
    lines = reason(%w[Gemfile.lock], range: 'origin/main...HEAD')

    expect(lines).to include('  - Gemfile.lock (committed in origin/main...HEAD)')
    expect(lines.join("\n")).not_to include('working tree')
  end

  it 'leaves the source unknown when the attributing diffs fail, never guessing one' do
    lines = reason(%w[Gemfile], range: 'HEAD~1', diff: ->(_range) { [nil, 'bad revision (git exited 128)'] })

    expect(lines).to include('  - Gemfile (source unknown: git could not attribute it)')
  end

  it 'notes the working tree when only an unlisted path came from it' do
    paths = (1..11).map { |n| format('config/initializers/i%02d.rb', n) }
    diff = ->(range) { range == 'HEAD' ? [[paths.last], nil] : [paths.first(10), nil] }

    lines = reason(paths, range: 'HEAD~1', diff: diff)

    expect(lines).to include('  ... and 1 more')
    expect(lines.last).to start_with('Uncommitted changes are included')
  end
end
