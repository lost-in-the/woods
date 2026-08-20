# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'woods/watch/daemon'

RSpec.describe Woods::Watch::Daemon do
  let(:root) { Dir.mktmpdir('woods_watch_root') }
  let(:output_dir) { Dir.mktmpdir('woods_watch_out') }
  # The real extractor bumps the generation as the last write of a successful
  # run (that is the contract the daemon reads), so the stub does too.
  let(:extractor) do
    instance_spy('Woods::Extractor').tap do |double|
      allow(double).to receive(:extract_changed) { publish_generation('incremental') && ['Thing'] }
      allow(double).to receive(:extract_all) { publish_generation('full') && {} }
    end
  end
  let(:reloader) { instance_double(Woods::Watch::Daemon::RailsReloader, enabled?: true, reload!: true) }

  after { FileUtils.rm_rf([root, output_dir]) }

  # catch_up is off by default here so the behaviour under test is the batch
  # the example hands over, not the state of the tmpdir. The startup
  # reconciliation has its own describe block below.
  def build(**overrides)
    described_class.new(
      output_dir: output_dir,
      root: root,
      extractor_factory: -> { extractor },
      reloader: reloader,
      debounce: 0,
      catch_up: false,
      **overrides
    )
  end

  def publish_generation(reason)
    Woods::Generation.new(output_dir: output_dir).bump!(reason: reason)
  end

  def touch(relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    relative
  end

  def status
    # AtomicFile.read, not File.read: this suite runs with a US-ASCII default
    # external encoding, and the daemon writes status reasons containing em
    # dashes. Reading them the naive way is the bug this helper would otherwise
    # reproduce rather than test around.
    JSON.parse(Woods::AtomicFile.read(File.join(output_dir, Woods::Watch::Status::FILENAME)))
  end

  def write_graph_with_paths(paths)
    File.write(
      File.join(output_dir, 'dependency_graph.json'),
      JSON.generate('file_map' => paths.to_h { |path| [path, ['SomeUnit']] })
    )
  end

  describe 'classification' do
    it 'does nothing for paths no extractor cares about' do
      result = build.process(['README.md'])

      expect(result[:action]).to eq(:ignore)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'extracts directly for files Woods reads as bytes' do
      touch('config/locales/en.yml')

      result = build.process(['config/locales/en.yml'])

      expect(result[:action]).to eq(:incremental)
      expect(reloader).not_to have_received(:reload!)
      expect(extractor).to have_received(:extract_changed)
    end

    it 'reloads before extracting when an autoloaded constant changed' do
      touch('app/models/user.rb')

      result = build.process(['app/models/user.rb'])

      expect(reloader).to have_received(:reload!)
      expect(result[:action]).to eq(:incremental)
    end
  end

  describe 'restart triggers' do
    it 'refuses to extract when boot-captured state changed' do
      result = build.process(['config/initializers/redis.rb'])

      expect(result[:action]).to eq(:restart)
      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('config/initializers/redis.rb')
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'escalates a reload to a restart when the app cannot reload' do
      allow(reloader).to receive(:enabled?).and_return(false)

      result = build.process(['app/models/user.rb'])

      expect(result[:action]).to eq(:restart)
      expect(reloader).not_to have_received(:reload!)
    end

    it 'records the restart in the status file so a reader can see why' do
      build.process(['Gemfile.lock'])

      expect(status['state']).to eq('degraded')
      expect(status['reason']).to include('restart required')
    end
  end

  describe 'failure posture' do
    it 'degrades rather than crashing when a mid-edit syntax error breaks the reload' do
      # SyntaxError is a ScriptError, not a StandardError — rescuing only the
      # latter would let a half-typed file kill the daemon.
      allow(reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end')
      touch('app/models/user.rb')

      result = nil
      expect { result = build.process(['app/models/user.rb']) }.not_to raise_error

      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('SyntaxError')
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'degrades rather than crashing when extraction itself raises' do
      allow(extractor).to receive(:extract_changed).and_raise(StandardError, 'boom')
      touch('config/locales/en.yml')

      result = build.process(['config/locales/en.yml'])

      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('boom')
    end

    it 'never advances the generation over work that did not land' do
      allow(extractor).to receive(:extract_changed).and_raise(StandardError, 'boom')
      touch('config/locales/en.yml')
      daemon = build

      before = daemon.generation.current.number
      daemon.process(['config/locales/en.yml'])

      expect(daemon.generation.current.number).to eq(before)
    end

    it 'keeps working after a failure once the cause is gone' do
      touch('app/models/user.rb')
      daemon = build

      allow(reloader).to receive(:reload!).and_raise(SyntaxError, 'unexpected end')
      expect(daemon.process(['app/models/user.rb'])[:state]).to eq(:degraded)

      allow(reloader).to receive(:reload!).and_return(true)
      expect(daemon.process(['app/models/user.rb'])[:state]).to eq(:running)
    end
  end

  describe 'storm handling' do
    it 'falls back to a full extraction above the threshold' do
      paths = Array.new(6) { |i| touch("app/services/svc_#{i}.rb") }

      result = build(full_extraction_threshold: 3).process(paths)

      expect(result[:action]).to eq(:full)
      expect(extractor).to have_received(:extract_all)
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'stays incremental at or below the threshold' do
      paths = Array.new(3) { |i| touch("app/services/svc_#{i}.rb") }

      result = build(full_extraction_threshold: 3).process(paths)

      expect(result[:action]).to eq(:incremental)
      expect(extractor).not_to have_received(:extract_all)
    end
  end

  describe 'publishing' do
    # The extractor owns the bump; the daemon reports it. Two bumps per cycle
    # would make the counter lie about how many times the index moved.
    it 'reports the generation the extraction published' do
      touch('config/locales/en.yml')
      daemon = build

      result = nil
      expect { result = daemon.process(['config/locales/en.yml']) }
        .to change { daemon.generation.current.number }.by(1)
      expect(result[:generation]).to eq(daemon.generation.current.number)
    end

    it 'does not mint a generation of its own when extraction publishes none' do
      allow(extractor).to receive(:extract_changed).and_return(['Thing'])
      touch('config/locales/en.yml')
      daemon = build

      expect { daemon.process(['config/locales/en.yml']) }
        .not_to(change { daemon.generation.current.number })
    end

    it 'leaves the generation alone when nothing was relevant' do
      touch('config/locales/en.yml')
      daemon = build
      daemon.process(['config/locales/en.yml'])

      expect { daemon.process(['README.md']) }.not_to(change { daemon.generation.current.number })
    end

    it 'reports a running state with the current generation' do
      touch('config/locales/en.yml')
      daemon = build
      daemon.process(['config/locales/en.yml'])

      expect(status).to include('state' => 'running', 'last_action' => 'incremental')
      expect(status['generation']).to eq(daemon.generation.current.number)
    end
  end

  # `Extractor#publish_generation` rescues its own failures so a good index is
  # not thrown away over an unwritable marker. That is right, but the marker is
  # the freshness contract: without it every reader keeps serving the previous
  # index while the daemon reports `running`, and the next incremental may be a
  # no-op that bumps nothing either. Not raising was right; not noticing was
  # not.
  describe 'an extraction that writes units without publishing a generation' do
    let(:silent_extractor) do
      instance_spy('Woods::Extractor').tap do |double|
        allow(double).to receive(:extract_changed).and_return(['Thing'])
        allow(double).to receive(:extract_all).and_return({})
      end
    end

    it 'reports degraded rather than running' do
      result = build(extractor_factory: -> { silent_extractor }).process([touch('app/models/user.rb')])

      expect(result[:state]).to eq(:degraded)
      expect(result[:reason]).to include('generation did not advance')
      expect(status['state']).to eq('degraded')
    end

    it 'carries the paths forward so a later cycle republishes them' do
      daemon = build(extractor_factory: -> { silent_extractor })
      path = touch('app/models/user.rb')
      daemon.process([path])

      # The next cycle bumps normally; the carried path rides along with it.
      allow(silent_extractor).to receive(:extract_changed) do |paths|
        publish_generation('incremental')
        paths
      end
      result = daemon.process([])

      expect(result[:state]).to eq(:running)
      expect(result[:touched]).to include(File.join(root, path))
    end

    # A no-op incremental deliberately does not bump. Reading that as a broken
    # publish would degrade the daemon on every ignorable batch.
    it 'stays running when the extractor wrote nothing at all' do
      allow(silent_extractor).to receive(:extract_changed).and_return([])

      result = build(extractor_factory: -> { silent_extractor }).process([touch('app/models/user.rb')])

      expect(result[:state]).to eq(:running)
    end
  end

  describe '#run' do
    let(:fake_watcher) { FakeWatcher.new }

    # Delivers one canned batch, then lets the daemon stop it.
    class FakeWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
      attr_reader :batches, :stopped

      def initialize
        @batches = []
        @stopped = false
      end

      def queue(paths)
        @batches << paths
      end

      def start(&on_change)
        @batches.each do |batch|
          break if @stopped

          on_change.call(batch)
        end
      end

      def stop
        @stopped = true
      end
    end

    it 'processes batches the watcher delivers and reports why it ended' do
      touch('config/locales/en.yml')
      fake_watcher.queue(['config/locales/en.yml'])

      expect(build(watcher: fake_watcher).run).to eq(:stopped)
      expect(extractor).to have_received(:extract_changed)
    end

    it 'stops the watcher and reports a restart when boot state changes' do
      fake_watcher.queue(['config/initializers/redis.rb'])
      fake_watcher.queue(['config/locales/en.yml'])

      expect(build(watcher: fake_watcher).run).to eq(:restart_required)
      expect(fake_watcher.stopped).to be(true)
      # The second batch must not be processed after a restart is demanded.
      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'leaves a stopped status behind so a reader knows nothing is maintaining the index' do
      build(watcher: fake_watcher).run

      expect(status['state']).to eq('stopped')
    end
  end

  # Callers stand down when a daemon is alive, so "alive" has to mean "covered".
  # A daemon that only ever reacts to events it personally witnessed is blind to
  # anything that changed before it started — and the documented hook pattern
  # (start a daemon, then sync) hits exactly that.
  describe 'startup catch-up' do
    let(:fake_watcher) { FakeWatcher.new }

    it 'reconciles changes that predate startup' do
      touch('app/services/before_the_daemon.rb')

      build(watcher: fake_watcher, catch_up: true).run

      expect(extractor).to have_received(:extract_changed) do |paths|
        expect(paths).to include(a_string_ending_with('app/services/before_the_daemon.rb'))
      end
    end

    it 'does nothing when every file predates the last successful extraction' do
      touch('app/services/already_indexed.rb')
      # The generation file is the watermark: written last on a successful run.
      sleep 0.01
      publish_generation('full')

      build(watcher: fake_watcher, catch_up: true).run

      expect(extractor).not_to have_received(:extract_changed)
      expect(extractor).not_to have_received(:extract_all)
    end

    it 'treats a missing index as everything being uncovered' do
      Array.new(4) { |i| touch("app/services/svc_#{i}.rb") }

      build(watcher: fake_watcher, catch_up: true, full_extraction_threshold: 2).run

      # No generation file at all means no index, and the storm threshold
      # correctly turns "every file" into one full extraction.
      expect(extractor).to have_received(:extract_all)
    end

    it 'can be turned off for a host that syncs by another route' do
      touch('app/services/before_the_daemon.rb')

      build(watcher: fake_watcher, catch_up: false).run

      expect(extractor).not_to have_received(:extract_changed)
    end

    it 'reconciles a deletion that predates startup' do
      # The index claims a path that no longer exists. Nothing on disk moved,
      # so the mtime scan alone would call the index current — TreeScan only
      # walks files that exist.
      publish_generation('full')
      write_graph_with_paths([File.join(root, 'app/services/deleted_service.rb')])

      build(watcher: fake_watcher, catch_up: true).run

      # An *empty* change set, deliberately: it reaches the ghosts through the
      # extractor's bounded sweep. Naming the path would make the deletion
      # authoritative for unit types the sweep exists to protect (nominal
      # paths, class-based units).
      expect(extractor).to have_received(:extract_changed).with([])
    end

    it 'ignores vanished paths outside the watched root' do
      # Framework units and indexes restored from CI artifacts register paths
      # under other roots; neither is a deletion in this worktree.
      publish_generation('full')
      write_graph_with_paths(['/somewhere/else/app/models/thing.rb'])

      build(watcher: fake_watcher, catch_up: true).run

      expect(extractor).not_to have_received(:extract_changed)
    end
  end

  # The debounce is only worth having if events landing inside the window join
  # the cycle rather than queueing behind it.
  describe 'debounce coalescing' do
    it 'folds events that arrive during the settle window into one cycle' do
      first = touch('app/services/saved.rb')
      second = touch('app/services/formatted.rb')

      daemon = build(debounce: 0.2)
      # Stand in for the formatter's write landing mid-window. The real path is
      # the watcher thread calling #enqueue while the drain loop sleeps in
      # #settle; what matters is that the cycle after the window picks it up
      # instead of leaving it for a second cycle.
      allow(daemon).to receive(:settle) { daemon.send(:enqueue, [second]) }

      daemon.send(:enqueue, [first])
      daemon.send(:drain)

      expect(extractor).to have_received(:extract_changed).once do |paths|
        expect(paths).to contain_exactly(
          a_string_ending_with('app/services/saved.rb'),
          a_string_ending_with('app/services/formatted.rb')
        )
      end
    end

    it 'counts only actionable paths towards the storm threshold' do
      paths = Array.new(6) { |i| touch("docs/note_#{i}.md") } + [touch('app/models/user.rb')]

      result = build(full_extraction_threshold: 3).process(paths)

      # Six markdown files plus one model is a one-model change.
      expect(result[:action]).to eq(:incremental)
      expect(extractor).not_to have_received(:extract_all)
    end
  end

  # `listen` delivers callbacks from its own thread pool, so two batches can
  # race into `drain`. The guard has to be an atomic test-and-set — a plain
  # boolean is check-then-act, and both threads can read false before either
  # writes true.
  describe 'drain concurrency' do
    it 'never runs two cycles at once and loses nothing when a drain is refused' do
      in_extraction = Queue.new
      release = Queue.new
      concurrent = { now: 0, max: 0 }
      tally = Mutex.new

      allow(extractor).to receive(:extract_changed) do |paths|
        tally.synchronize do
          concurrent[:now] += 1
          concurrent[:max] = [concurrent[:max], concurrent[:now]].max
        end
        in_extraction << true
        release.pop
        tally.synchronize { concurrent[:now] -= 1 }
        publish_generation('incremental')
        paths
      end

      daemon = build
      first = touch('app/services/one.rb')
      second = touch('app/services/two.rb')

      holder = Thread.new do
        daemon.send(:enqueue, [first])
        daemon.send(:drain)
      end
      in_extraction.pop # the first drain is mid-extraction, holding the guard

      racer = Thread.new do
        daemon.send(:enqueue, [second])
        daemon.send(:drain)
      end
      # The racing drain must return promptly — refused, not queued behind the
      # lock, and above all not running a second cycle in parallel.
      expect(racer.join(2)).not_to be_nil

      release << true
      # The holder's loop picks up the batch the refused drain enqueued.
      in_extraction.pop
      release << true
      expect(holder.join(2)).not_to be_nil

      expect(concurrent[:max]).to eq(1)
      expect(extractor).to have_received(:extract_changed).twice
    end
  end

  # Carried paths survived within a run but were dropped at shutdown, and the
  # mtime watermark does not cover them: if another writer bumps the generation
  # after the daemon carried a path forward, the watermark is newer than that
  # file and catch-up skips it — lost for good, with the status saying running.
  describe 'pending paths across a restart' do
    let(:fake_watcher) { FakeWatcher.new }

    def pending_file
      File.join(output_dir, 'watch_pending.json')
    end

    it 'persists what a degraded cycle carried forward' do
      touch('config/locales/en.yml')
      allow(extractor).to receive(:extract_changed).and_raise(StandardError, 'boom')
      daemon = build(watcher: fake_watcher)
      fake_watcher.queue(['config/locales/en.yml'])

      daemon.run

      expect(JSON.parse(File.read(pending_file)))
        .to include(a_string_ending_with('config/locales/en.yml'))
    end

    it 'replays them at the next startup even when the watermark has moved past' do
      relative = touch('config/locales/en.yml')
      File.write(pending_file, JSON.generate([File.join(root, relative)]))
      # A later writer bumped the generation, so the watermark is newer than the
      # carried file and the mtime scan alone would find nothing.
      sleep 0.01
      publish_generation('full')

      build(watcher: fake_watcher, catch_up: true).run

      expect(extractor).to have_received(:extract_changed) do |paths|
        expect(paths).to include(a_string_ending_with('config/locales/en.yml'))
      end
    end

    it 'clears the file once the work lands' do
      touch('config/locales/en.yml')
      build(watcher: fake_watcher).run

      expect(JSON.parse(File.read(pending_file))).to be_empty
    end

    # Thread#kill bypasses rescue blocks, so a batch #process already drained
    # from @pending (the popped-but-not-yet-carried-forward window) evaporated
    # if the thread running it was killed mid-cycle — persist_pending then had
    # nothing left to write and clobbered the durable file with []. #process
    # now guards the drained batch with its own ensure, independent of what
    # killed the thread running it.
    it 'survives the thread that drained it being killed mid-cycle' do
      entered = Queue.new
      release = Queue.new
      allow(extractor).to receive(:extract_changed) do |paths|
        entered << true
        release.pop
        paths
      end

      relative = touch('config/locales/en.yml')
      daemon = build

      worker = Thread.new { daemon.send(:process, [relative]) }
      Timeout.timeout(5) { entered.pop } # wait until the batch is mid-extraction

      worker.kill
      raise 'worker thread did not exit after #kill' unless worker.join(5)

      daemon.send(:persist_pending)

      expect(JSON.parse(File.read(pending_file)))
        .to include(a_string_ending_with('config/locales/en.yml'))
    end
  end

  # PipelineLock stops two daemons interleaving writes; nothing stopped them
  # both existing, doubling the extraction work and making one status file
  # answer for two processes.
  describe 'a second daemon on one index' do
    it 'stands down when another live daemon holds the index' do
      allow_any_instance_of(Woods::Watch::Status).to receive(:alive?).and_return(true)
      allow_any_instance_of(Woods::Watch::Status)
        .to receive(:read).and_return({ 'state' => 'running', 'pid' => Process.pid + 100_000 })

      expect(build.run).to eq(:already_running)
    end

    it 'starts anyway when WOODS_IGNORE_WATCH is set' do
      allow_any_instance_of(Woods::Watch::Status).to receive(:alive?).and_return(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WOODS_IGNORE_WATCH').and_return('1')

      daemon = build(idle_timeout: 0.01)
      expect(daemon.run).not_to eq(:already_running)
    end

    # A crashed predecessor must not lock the index out — alive? requires the
    # recorded pid to still exist, so an ordinary start is unaffected.
    it 'starts when no daemon is recorded' do
      daemon = build(idle_timeout: 0.01)
      expect(daemon.run).not_to eq(:already_running)
    end

    # Standing down must leave no trace. #run's ensure used to fire on the
    # early return too, so the daemon that correctly refused to start still
    # persisted an empty pending file over the live daemon's carried paths and
    # published `stopped` under its own pid over the live `running` record —
    # read as dead for up to HEARTBEAT_INTERVAL, long enough for a
    # `watch_status || start` hook to boot a third daemon and for
    # `woods:incremental` to stop standing down.
    it 'leaves the live daemon record and its carried paths untouched when standing down' do
      status_path = File.join(output_dir, Woods::Watch::Status::FILENAME)
      pending_path = File.join(output_dir, 'watch_pending.json')
      # A real record for a live foreign daemon: the parent process is alive by
      # definition, on this host, and not this pid.
      Woods::AtomicFile.write(status_path, JSON.generate(
                                             'state' => 'running', 'reason' => nil, 'generation' => 3,
                                             'pid' => Process.ppid,
                                             'host' => Woods::Watch::Status.host_identity,
                                             'updated_at' => Time.now.utc.iso8601
                                           ))
      Woods::AtomicFile.write(pending_path,
                              JSON.generate([File.join(root, 'app/models/carried.rb')]))
      status_before = File.binread(status_path)
      pending_before = File.binread(pending_path)

      expect(build.run).to eq(:already_running)

      expect(File.binread(status_path)).to eq(status_before)
      expect(File.binread(pending_path)).to eq(pending_before)
    end
  end

  # Every cycle writes generation.json and status.json, so watching the output
  # directory means each cycle manufactures the events that trigger the next.
  describe 'the output directory' do
    it 'is ignored when it sits inside the watched tree' do
      inside = File.join(root, '.woods')
      FileUtils.mkdir_p(inside)
      daemon = described_class.new(
        output_dir: inside, root: root, extractor_factory: -> { extractor },
        reloader: reloader, debounce: 0, catch_up: false
      )

      expect(daemon.send(:ignored_directories)).to include('.woods')
    end

    it 'is left alone when it sits outside the watched tree' do
      expect(build.send(:ignored_directories))
        .to eq(Woods::Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES)
    end
  end

  # start_watching's polling fallback reassigns @watcher mid-run (daemon.rb
  # ~565-574). A local `watcher` variable captured before the fallback goes
  # stale — the heartbeat's idle-stop kept acting on the discarded pre-fallback
  # watcher instead of the one actually running, so an idle daemon that fell
  # back to polling never actually stopped.
  describe 'watcher fallback keeps @watcher current' do
    # Raises on #start every time, forcing start_watching's fallback path.
    class RaisingWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
      def start(&_on_change)
        raise Woods::Watch::WatcherError, 'inotify exhausted'
      end

      def stop; end
    end

    # Blocks in #start (like a real watcher's event loop) until #stop flips
    # the flag — the same shape as the FakeWatcher/idle_watcher fixtures
    # elsewhere in this file.
    class BlockingWatcher # rubocop:disable Lint/ConstantDefinitionInBlock
      attr_reader :stop_count

      def initialize
        @stopped = false
        @stop_count = 0
      end

      def start(&_on_change)
        sleep(0.02) until @stopped
      end

      def stop
        @stop_count += 1
        @stopped = true
      end
    end

    it 'stops the fallback watcher on idle, not the watcher captured before the fallback' do
      initial_watcher = RaisingWatcher.new
      fallback_watcher = BlockingWatcher.new
      allow(Woods::Watch::Watcher).to receive(:build).and_return(fallback_watcher)

      daemon = build(watcher: initial_watcher, idle_timeout: 0.1)

      reason = Timeout.timeout(5) { daemon.run }

      expect(reason).to eq(:idle)
      # >= 1, not ==: shutdown's own `@watcher&.stop` runs unconditionally
      # after the heartbeat's idle-stop already called it once — a harmless
      # second call to an idempotent #stop. What matters is that it is the
      # fallback watcher receiving it at all, not the stale pre-fallback one.
      expect(fallback_watcher.stop_count).to be >= 1
    end
  end
end
