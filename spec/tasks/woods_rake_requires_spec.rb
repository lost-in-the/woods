# frozen_string_literal: true

require 'spec_helper'
require 'rake'

# Guards the seam every other spec papers over.
#
# `rake woods:watch` loaded and started cleanly with no `require
# 'woods/extractor'`, then raised `NameError: uninitialized constant
# Woods::Extractor` on its first real cycle — and because a raising extraction
# degrades rather than crashes, the daemon then heartbeated `degraded` forever.
# Found only by running the task against a real app.
#
# The suite could not catch it because every daemon spec requires the extractor
# in its own setup and injects an `extractor_factory`, so the lazy constant
# lookup in the default factory never ran unresolved. These examples read the
# task bodies as text instead: cheap, and they fail for exactly the right
# reason.
RSpec.describe 'lib/tasks/woods.rake requires' do
  # Explicit UTF-8: the rake file has em dashes in its comments, and a
  # US-ASCII default external encoding makes every match? raise.
  let(:source) { File.read(File.expand_path('../../lib/tasks/woods.rake', __dir__), encoding: 'UTF-8') }

  # Task names whose bodies use Woods::Extractor behind an explicit require.
  tasks_needing_extractor = %w[extract incremental watch refresh].freeze

  # From the `task <name>` line to the next task/desc at the same indent.
  def task_body(name)
    lines = source.lines
    start = lines.index { |line| line.match?(/^  task[ :]+#{Regexp.escape(name)}\b/) }
    raise "could not locate the #{name} task in lib/tasks/woods.rake" if start.nil?

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.match?(/^  (desc|task)\b/) } || rest.length
    rest[0...stop].join
  end

  tasks_needing_extractor.each do |name|
    it "woods:#{name} requires woods/extractor before using it" do
      body = task_body(name)
      next unless body.include?('Woods::Extractor')

      expect(body).to(
        include("require 'woods/extractor'"),
        "woods:#{name} names Woods::Extractor but never requires it — it will NameError at runtime"
      )
    end
  end

  it 'woods:watch requires both the extractor and the daemon' do
    body = task_body('watch')

    expect(body).to include("require 'woods/extractor'")
    expect(body).to include("require 'woods/watch/daemon'")
  end

  # The daemon resolves Woods::Extractor lazily inside its default factory, so
  # nothing fails until a cycle actually runs. Pin that this is the shape.
  it 'the daemon default factory names the extractor lazily' do
    daemon_source = File.read(File.expand_path('../../lib/woods/watch/daemon.rb', __dir__), encoding: 'UTF-8')

    expect(daemon_source).to include('Woods::Extractor.new(output_dir: @output_dir)')
    expect(daemon_source).not_to include("require 'woods/extractor'")
  end
end
