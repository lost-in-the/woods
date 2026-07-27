# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'

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

  # The task bodies were only half the surface. `woods_with_extraction_lock` is
  # on the path of every write task, and its default `wait` reads a constant
  # from the daemon — resolved *above* its own requires, it NameError'd every
  # incremental sync. Same load-order bug as the missing require it was written
  # alongside.
  describe 'shared helpers' do
    def helper_body(name)
      lines = source.lines
      start = lines.index { |line| line.match?(/^  def #{Regexp.escape(name)}\b/) }
      raise "could not locate the #{name} helper in lib/tasks/woods.rake" if start.nil?

      rest = lines[(start + 1)..]
      stop = rest.index { |line| line.match?(/^  (def|desc|task)\b/) } || rest.length
      rest[0...stop].join
    end

    it 'requires before naming any constant those requires provide' do
      body = helper_body('woods_with_extraction_lock')
      lines = body.lines

      first_require = lines.index { |line| line.include?("require 'woods/watch/daemon'") }
      first_use = lines.index { |line| line.include?('Woods::Watch::Daemon') && !line.include?('require') }

      expect(first_require).not_to(be_nil, 'the helper must require the daemon it names')
      expect(first_use).to(
        be > first_require,
        'woods_with_extraction_lock names Woods::Watch::Daemon before requiring it — NameError at runtime'
      )
    end

    it 'requires the pipeline lock it constructs' do
      expect(helper_body('woods_with_extraction_lock'))
        .to include("require 'woods/coordination/pipeline_lock'")
    end

    it 'requires the status class the coverage helper reads' do
      expect(helper_body('woods_daemon_coverage')).to include("require 'woods/watch/status'")
    end

    # The text checks above encode *why* it broke; this one just runs it. The
    # helper takes no Rails, so the load-order path every write task depends on
    # is directly executable — which is the check that would have caught both
    # NameErrors without anyone reasoning about requires at all.
    describe 'executed against a real directory' do
      before { load File.expand_path('../../lib/tasks/woods.rake', __dir__) }

      it 'acquires, yields and releases without a booted Rails' do
        Dir.mktmpdir('woods_helper') do |dir|
          ran = false
          Object.new.send(:woods_with_extraction_lock, dir) { ran = true }

          expect(ran).to be(true)
          expect(Dir.children(dir).grep(/\.lock\z/)).to be_empty
        end
      end

      it 'honours an explicit wait without consulting the daemon default' do
        Dir.mktmpdir('woods_helper') do |dir|
          expect { Object.new.send(:woods_with_extraction_lock, dir, wait: 0) { nil } }.not_to raise_error
        end
      end
    end
  end

  # The daemon resolves Woods::Extractor lazily inside its default factory, so
  # nothing fails until a cycle actually runs. Pin that this is the shape.
  it 'the daemon default factory names the extractor lazily' do
    daemon_source = File.read(File.expand_path('../../lib/woods/watch/daemon.rb', __dir__), encoding: 'UTF-8')

    expect(daemon_source).to include('Woods::Extractor.new(output_dir: @output_dir)')
    expect(daemon_source).not_to include("require 'woods/extractor'")
  end
end
