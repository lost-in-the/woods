# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/coordination/pipeline_lock'

# `PipelineLock` staleness is mtime-only: a holder that goes quiet for longer
# than `stale_timeout` has its lock retired by the next writer, which is exactly
# the two-writer clobber the lock exists to prevent — silently, with the
# generation bumped afterwards so the clobbered index reads as fresh.
#
# `#touch` exists for that, and the daemon calls it every cycle. The rake path
# (`woods:extract`, `woods:incremental`, `woods:refresh`) did not, so the
# protection covered the writer least likely to be slow and missed the three
# most likely.
#
# These drive `PipelineLock` directly rather than booting rake: the rake helper
# is a private method on `main` in a task file, and what needs guarding is the
# property (a held lock stays fresh while work runs), not the plumbing. The
# plumbing is covered by `woods_rake_requires_spec.rb`, which reads the task
# source as text.
RSpec.describe 'extraction lock heartbeat' do
  let(:lock_dir) { Dir.mktmpdir('woods_lock_hb') }

  after { FileUtils.rm_rf(lock_dir) }

  def build_lock(stale_timeout:)
    Woods::Coordination::PipelineLock.new(
      lock_dir: lock_dir, name: 'extraction', stale_timeout: stale_timeout
    )
  end

  it 'lets a contender retire a lock whose holder never touches it' do
    holder = build_lock(stale_timeout: 0.2)
    expect(holder.acquire).to be true

    sleep 0.3
    contender = build_lock(stale_timeout: 0.2)

    expect(contender.acquire).to be true
  end

  it 'keeps the lock un-retirable while the holder touches it' do
    holder = build_lock(stale_timeout: 0.2)
    expect(holder.acquire).to be true

    3.times do
      sleep 0.1
      holder.touch
    end

    contender = build_lock(stale_timeout: 0.2)
    expect(contender.acquire).to be false
  end

  # A tick that lands after release must not revive a lock this process no
  # longer holds — the heartbeat thread is joined rather than killed, so a final
  # tick racing `release` is reachable.
  it 'ignores a touch from a process that no longer holds the lock' do
    holder = build_lock(stale_timeout: 5)
    holder.acquire
    holder.release

    expect(holder.touch).to be false
  end
end
