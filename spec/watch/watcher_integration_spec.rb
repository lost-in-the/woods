# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/watch/daemon'

# The seam every other watch spec injects around.
#
# `daemon_spec.rb` hands `#process` a path array; `polling_watcher_spec.rb`
# drives `#poll` synchronously. Both are the right shape for what they test,
# and between them nothing ever asserts that a *real file write* reaches
# extraction — the watcher's own thread, the callback that merges into
# `@pending`, the debounce, and the drain loop are only exercised as separate
# halves. That gap is exactly where the daemon's bugs have actually lived:
# a `stop` racing startup, a callback that processed inline instead of
# enqueueing, whole-second mtimes losing a write. None of those are visible
# from either half alone.
#
# The extractor is still a double: what is under test is the path from an
# `File.write` to `extract_changed` being called with that path, not what
# extraction produces. `spec/integration/watch_daemon_spec.rb` owns the other
# half against a real Rails app.
RSpec.describe 'a real watcher driving a real daemon' do
  let(:root) { Dir.mktmpdir('woods_watch_e2e_root') }
  let(:output_dir) { Dir.mktmpdir('woods_watch_e2e_out') }
  let(:batches) { Queue.new }

  let(:extractor) do
    instance_spy('Woods::Extractor').tap do |double|
      allow(double).to receive(:extract_changed) do |paths|
        Woods::Generation.new(output_dir: output_dir).bump!(reason: 'incremental')
        batches << paths
        ['Thing']
      end
    end
  end

  # Short but not zero: the point is that the real sleep-scan-diff loop runs.
  let(:watcher) { Woods::Watch::PollingWatcher.new(root: root, interval: 0.05) }

  let(:daemon) do
    Woods::Watch::Daemon.new(
      output_dir: output_dir, root: root, watcher: watcher,
      extractor_factory: -> { extractor },
      reloader: instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true),
      debounce: 0.1, catch_up: false
    )
  end

  before { FileUtils.mkdir_p(File.join(root, 'app/models')) }

  after do
    daemon.stop
    @thread&.join(5)
    FileUtils.rm_rf([root, output_dir])
  end

  def write(relative, contents = "class Thing; end\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  # Take the watcher's baseline here rather than letting `start` take it, so
  # the write below cannot land in the gap before the daemon's thread is
  # scheduled. `start` finds the snapshot already present and skips priming, so
  # the scan/diff/callback path under test is untouched.
  def run_daemon
    watcher.primed_now?
    @thread = Thread.new { daemon.run }
  end

  def next_batch(timeout: 10)
    Timeout.timeout(timeout) { batches.pop }
  rescue Timeout::Error
    raise 'no extraction ran within the timeout — the watcher never reached the daemon'
  end

  it 'extracts a file created after the daemon started' do
    run_daemon
    write('app/models/user.rb')

    expect(next_batch).to include(File.join(root, 'app/models/user.rb'))
  end

  # Create, fold into the baseline, rewrite — all inside one wall-clock second.
  # A snapshot keyed on `mtime.to_i` reports nothing here, and no later event
  # ever mentions the file again.
  it 'extracts a rewrite that lands in the same second as the baseline' do
    # Byte-identical in *length*, so the size tiebreaker cannot rescue this —
    # only the fractional mtime distinguishes the two versions.
    created = write('app/models/post.rb', "# aaaa\nclass Post; end\n")
    watcher.poll # fold the creation into the baseline
    run_daemon

    File.write(created, "# bbbb\nclass Post; end\n")

    expect(next_batch).to include(created)
  end

  # The debounce is only a coalescer because the callback enqueues and returns
  # rather than processing inline. Driven end to end, a save-plus-formatter-
  # plus-linter burst has to arrive as *one* `extract_changed` carrying all
  # three paths — if the work moved back into the callback each write would get
  # its own batch of one, and the first batch would not contain the others.
  it 'coalesces a burst of writes into a single extraction' do
    run_daemon

    paths = %w[a b c].map { |name| write("app/models/#{name}.rb") }

    expect(next_batch).to include(*paths)
  end

  it 'reports a deletion, which only a diffing watcher can see' do
    created = write('app/models/gone.rb')
    watcher.poll
    run_daemon

    File.delete(created)

    expect(next_batch).to include(created)
  end

  # `stop` and the watcher's startup race by construction — the signal handler
  # runs on a different thread than `start`. A `stop` that lands first must not
  # be overwritten by the loop, or the daemon becomes unstoppable.
  it 'honours a stop that arrives before the loop begins' do
    watcher.stop

    expect { Timeout.timeout(5) { daemon.run } }.not_to raise_error
    expect(extractor).not_to have_received(:extract_changed)
  end
end
