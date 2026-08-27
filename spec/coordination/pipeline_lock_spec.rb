# frozen_string_literal: true

require 'spec_helper'
require 'io/wait'
require 'tmpdir'
require 'woods'
require 'woods/coordination/pipeline_lock'

RSpec.describe Woods::Coordination::PipelineLock do
  let(:lock_dir) { Dir.mktmpdir }
  let(:guard_path) { lock.send(:guard_path) }

  after do
    FileUtils.rm_rf(lock_dir)
  end

  subject(:lock) { described_class.new(lock_dir: lock_dir, name: 'extraction') }

  describe '#acquire' do
    it 'creates a lock file' do
      lock.acquire
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be true
    end

    it 'returns true on successful acquisition' do
      expect(lock.acquire).to be true
    end

    it 'returns false if already locked' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect(other_lock.acquire).to be false
    end

    it 'keeps a stable transaction guard after ownership is released' do
      expect(lock.acquire).to be true

      lock.release

      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be false
      expect(File.file?(guard_path)).to be true
    end
  end

  describe '#release' do
    it 'removes the lock file' do
      lock.acquire
      lock.release
      expect(File.exist?(File.join(lock_dir, 'extraction.lock'))).to be false
    end

    it 'does not raise if not locked' do
      expect { lock.release }.not_to raise_error
    end
  end

  describe '#with_lock' do
    it 'yields the block when lock acquired' do
      result = lock.with_lock { 42 }
      expect(result).to eq(42)
    end

    it 'releases lock after block completes' do
      lock.with_lock { 'work' }
      expect(lock.locked?).to be false
    end

    it 'releases lock on exception' do
      begin
        lock.with_lock { raise 'boom' }
      rescue RuntimeError
        nil
      end
      expect(lock.locked?).to be false
    end

    it 'raises LockError when lock unavailable' do
      lock.acquire
      other_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect do
        other_lock.with_lock { 'work' }
      end.to raise_error(Woods::Coordination::LockError)
    end
  end

  describe '#locked?' do
    it 'returns false when not locked' do
      expect(lock.locked?).to be false
    end

    it 'returns true when locked' do
      lock.acquire
      expect(lock.locked?).to be true
    end
  end

  describe 'stale lock detection' do
    it 'treats locks older than timeout as stale' do
      lock.acquire
      lock_path = File.join(lock_dir, 'extraction.lock')
      # Backdate the lock file
      FileUtils.touch(lock_path, mtime: Time.now - 3600)

      stale_lock = described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 1800)
      expect(stale_lock.acquire).to be true
    end

    it 'handles ENOENT when lock file is deleted between exist? and mtime checks' do
      lock_path = File.join(lock_dir, 'extraction.lock')
      # Create a lock file so File.exist? returns true
      File.write(lock_path, '{}')

      # Simulate the race: File.exist? sees the file, but File.mtime raises
      # ENOENT for the lock path (other paths, e.g. a graveyard file, behave
      # normally).
      allow(File).to receive(:mtime).and_call_original
      allow(File).to receive(:mtime).with(lock_path).and_raise(Errno::ENOENT)

      new_lock = described_class.new(lock_dir: lock_dir, name: 'extraction')
      expect { new_lock.acquire }.not_to raise_error
    end
  end

  describe '#retire_stale' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }
    let(:repair) do
      described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 60)
    end

    it 'reports a missing lock without creating one' do
      expect(repair.retire_stale).to eq(:missing)
      expect(File.exist?(lock_path)).to be(false)
    end

    it 'reports a current lock as not stale and preserves its ownership token' do
      expect(lock.acquire).to be(true)
      token = JSON.parse(File.read(lock_path)).fetch('token')

      expect(repair.retire_stale).to eq(:not_stale)
      expect(JSON.parse(File.read(lock_path)).fetch('token')).to eq(token)
    end

    it 'clears a genuinely stale lock' do
      expect(lock.acquire).to be(true)
      File.utime(Time.now - 120, Time.now - 120, lock_path)

      expect(repair.retire_stale).to eq(:cleared)
      expect(File.exist?(lock_path)).to be(false)
    end

    it 'serializes concurrent administrative cleaners' do
      expect(lock.acquire).to be(true)
      File.utime(Time.now - 120, Time.now - 120, lock_path)
      cleaners = 2.times.map do
        Thread.new do
          described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 60).retire_stale
        end
      end

      expect(cleaners.map(&:value)).to contain_exactly(:cleared, :missing)
      expect(File.exist?(lock_path)).to be(false)
      expect(File.file?(guard_path)).to be(true)
    end

    it 'preserves a fresh corrupt lock and clears it only after it becomes stale' do
      File.write(lock_path, '{not-json')

      expect(repair.retire_stale).to eq(:not_stale)
      expect(File.binread(lock_path)).to eq('{not-json')

      File.utime(Time.now - 120, Time.now - 120, lock_path)
      expect(repair.retire_stale).to eq(:cleared)
      expect(File.exist?(lock_path)).to be(false)
    end

    it 'backs off without clearing a fresh successor that wins before retirement' do
      expect(lock.acquire).to be(true)
      File.utime(Time.now - 120, Time.now - 120, lock_path)
      successor_token = 'fresh-successor'
      original_rename = File.method(:rename)
      raced = false

      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(lock_path, kind_of(String)) do |source, destination|
        unless raced
          raced = true
          retired = "#{lock_path}.raced-stale"
          original_rename.call(source, retired)
          File.write(source, JSON.generate(pid: Process.pid, token: successor_token))
          FileUtils.rm_f(retired)
        end
        original_rename.call(source, destination)
      end

      expect(repair.retire_stale).to eq(:not_stale)
      expect(JSON.parse(File.read(lock_path)).fetch('token')).to eq(successor_token)
    end
  end

  describe 'release ownership' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

    it 'does not delete a lock file that was taken over by another holder' do
      lock.acquire
      # Simulate a legitimate takeover after this holder went stale:
      # the file now carries someone else's token.
      File.write(lock_path, JSON.generate(pid: 99_999, token: 'someone-elses-token'))

      lock.release

      expect(File.exist?(lock_path)).to be true
    end

    it 'deletes the lock file when it still owns it' do
      lock.acquire
      lock.release

      expect(File.exist?(lock_path)).to be false
    end

    it 'handles the lock file already being gone' do
      lock.acquire
      FileUtils.rm_f(lock_path)

      expect { lock.release }.not_to raise_error
      expect(lock.locked?).to be false
    end
  end

  describe 'stale takeover race' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

    it 'backs off when another process retires the stale lock first' do
      File.write(lock_path, '{}')
      FileUtils.touch(lock_path, mtime: Time.now - 7200)

      # The racing process wins the atomic rename between our stale check
      # and our retirement attempt.
      allow(File).to receive(:rename).and_raise(Errno::ENOENT)

      expect(lock.acquire).to be false
      expect(lock.locked?).to be false
    end

    it 'restores the file and backs off if the retired lock is no longer stale' do
      # Simulates a competitor that already retired the stale lock and
      # created a FRESH one between our stale? check and our rename: retiring
      # blindly would clobber a live holder's lock and let both processes run.
      File.write(lock_path, JSON.generate(token: 'competitor-fresh'))
      # mtime is now (fresh), i.e. not older than stale_timeout.

      expect(lock.retire_stale).to eq(:not_stale)
      expect(File.exist?(lock_path)).to be true
      expect(JSON.parse(File.read(lock_path))['token']).to eq('competitor-fresh')
    end

    it 'restore_lock_unlocked does not clobber a lock created in the gap' do
      # After we rename a captured lock aside, a newer holder may O_EXCL-create
      # at @lock_path. Restoring via rename would overwrite it (double-hold);
      # the link-based restore must leave the newer holder untouched and simply
      # discard our aside copy.
      graveyard = "#{lock_path}.grave"
      File.write(graveyard, JSON.generate(token: 'ours-captured'))
      File.write(lock_path, JSON.generate(token: 'newer-holder'))

      lock.send(:restore_lock_unlocked, graveyard)

      expect(JSON.parse(File.read(lock_path))['token']).to eq('newer-holder')
      expect(File.exist?(graveyard)).to be false
    end

    it 'does not expose an administrative rename gap to another process' do
      expect(lock.acquire).to be(true)
      primary_path = lock_path
      cleaner_ready_r, cleaner_ready_w = IO.pipe
      continue_cleaner_r, continue_cleaner_w = IO.pipe
      cleaner_result_r, cleaner_result_w = IO.pipe
      contender_started_r, contender_started_w = IO.pipe
      contender_result_r, contender_result_w = IO.pipe
      release_contender_r, release_contender_w = IO.pipe

      cleaner_pid = fork do
        cleaner_ready_r.close
        continue_cleaner_w.close
        cleaner_result_r.close
        contender_started_r.close
        contender_started_w.close
        contender_result_r.close
        contender_result_w.close
        release_contender_r.close
        release_contender_w.close
        original_rename = File.method(:rename)
        File.define_singleton_method(:rename) do |source, destination|
          original_rename.call(source, destination)
          next unless source == primary_path

          cleaner_ready_w.write("renamed\n")
          cleaner_ready_w.flush
          continue_cleaner_r.read(1)
        end
        outcome = described_class.new(
          lock_dir: lock_dir, name: 'extraction', stale_timeout: 60
        ).retire_stale
        cleaner_result_w.write("#{outcome}\n")
        cleaner_result_w.flush
        exit!(0)
      end

      cleaner_ready_w.close
      continue_cleaner_r.close
      cleaner_result_w.close
      expect(cleaner_ready_r.gets).to eq("renamed\n")

      contender_pid = fork do
        cleaner_ready_r.close
        continue_cleaner_w.close
        cleaner_result_r.close
        contender_started_r.close
        contender_result_r.close
        release_contender_w.close
        contender = described_class.new(lock_dir: lock_dir, name: 'extraction')
        contender_started_w.write("started\n")
        contender_started_w.flush
        acquired = contender.acquire
        contender_result_w.write("#{acquired}\n")
        contender_result_w.flush
        release_contender_r.read(1) if acquired
        contender.release
        exit!(0)
      end

      contender_started_w.close
      contender_result_w.close
      release_contender_r.close
      expect(contender_started_r.gets).to eq("started\n")
      completed_during_gap = !contender_result_r.wait_readable(0.1).nil?

      continue_cleaner_w.write('.')
      continue_cleaner_w.close
      cleaner_outcome = cleaner_result_r.gets&.strip
      contender_outcome = contender_result_r.gets&.strip
      release_contender_w.write('.') if contender_outcome == 'true'
      release_contender_w.close
      Process.wait(cleaner_pid)
      Process.wait(contender_pid)

      expect(completed_during_gap).to be(false)
      expect(cleaner_outcome).to eq('not_stale')
      expect(contender_outcome).to eq('false')
      expect(lock.touch).to be(true)
    ensure
      continue_cleaner_w&.close unless continue_cleaner_w&.closed?
      release_contender_w&.close unless release_contender_w&.closed?
      [cleaner_pid, contender_pid].compact.each do |pid|
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      [
        cleaner_ready_r, cleaner_ready_w, continue_cleaner_r, continue_cleaner_w,
        cleaner_result_r, cleaner_result_w, contender_started_r, contender_started_w,
        contender_result_r, contender_result_w, release_contender_r, release_contender_w
      ].compact.each { |io| io.close unless io.closed? }
    end
  end

  describe 'path transaction interactions' do
    let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

    it 'does not let a contender acquire through the release rename gap' do
      expect(lock.acquire).to be(true)
      captured = Queue.new
      continue_release = Queue.new
      allow(lock).to receive(:own_lock?).and_wrap_original do |original, path|
        captured << true
        continue_release.pop
        original.call(path)
      end

      releasing = Thread.new { lock.release }
      captured.pop
      contender = described_class.new(lock_dir: lock_dir, name: 'extraction')
      acquiring = Thread.new { contender.acquire }
      # `own_lock?` is parked mid-release (captured above), holding the path
      # guard the contender's own acquire needs — a bounded join that times
      # out is the attempted-entry-then-observed-blocking proof; it does not
      # wait the full bound when nothing is actually blocking.
      completed_during_gap = acquiring.join(0.3) ? true : false

      continue_release << true
      releasing.join

      expect(completed_during_gap).to be(false)
      expect(acquiring.value).to be(true)
    ensure
      continue_release << true if releasing&.alive?
      releasing&.join(1)
      acquiring&.join(1)
      contender&.release
    end

    it 'does not let a cleaner rename the path during an ownership touch' do
      expect(lock.acquire).to be(true)
      refreshing = Queue.new
      continue_touch = Queue.new
      allow(File).to receive(:utime).and_wrap_original do |original, *arguments|
        if arguments.last == lock_path
          refreshing << true
          continue_touch.pop
        end
        original.call(*arguments)
      end

      touching = Thread.new { lock.touch }
      refreshing.pop
      cleaner = described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: 60)
      cleaning = Thread.new { cleaner.retire_stale }
      # `File.utime` is parked mid-touch (captured above), holding the path
      # guard the cleaner's own retire_stale needs — a bounded join that
      # times out is the observed-blocking proof.
      completed_during_touch = cleaning.join(0.3) ? true : false

      continue_touch << true

      expect(completed_during_touch).to be(false)
      expect(touching.value).to be(true)
      expect(cleaning.value).to eq(:not_stale)
    ensure
      continue_touch << true if touching&.alive?
      [touching, cleaning].compact.each { |thread| thread.join(1) }
    end
  end

  describe 'symlinked lock directory aliasing' do
    let(:real_dir) { Dir.mktmpdir('woods_lock_real') }
    let(:alias_parent) { Dir.mktmpdir('woods_lock_alias_parent') }
    let(:alias_dir) { File.join(alias_parent, 'alias') }
    let(:real_lock) { described_class.new(lock_dir: real_dir, name: 'extraction') }
    let(:alias_lock) { described_class.new(lock_dir: alias_dir, name: 'extraction') }

    before { FileUtils.ln_s(real_dir, alias_dir) }

    after do
      FileUtils.rm_rf(real_dir)
      FileUtils.rm_rf(alias_parent)
    end

    it 'derives the identical guard path for the real directory and a symlinked alias of it' do
      expect(alias_lock.send(:guard_path)).to eq(real_lock.send(:guard_path))
    end

    it 'blocks a symlink-path contender from entering the guard critical section the real-path lock holds' do
      entered = Queue.new
      continue = Queue.new
      allow(File).to receive(:utime).and_wrap_original do |original, *arguments|
        entered << true
        continue.pop
        original.call(*arguments)
      end
      expect(real_lock.acquire).to be(true)

      touching = Thread.new { real_lock.touch }
      entered.pop
      contender = Thread.new { alias_lock.retire_stale }
      still_blocked =
        begin
          Timeout.timeout(0.3) { contender.join }
          false
        rescue Timeout::Error
          true
        end

      continue << true
      touching.join(1)

      expect(still_blocked).to be(true)
      # Not stale (the real holder is actively touching it), so the aliased
      # contender's retire attempt correctly backs off once it is finally let
      # in — this proves the two aliases share one guard, not just that the
      # contender happened to be slow.
      expect(contender.value).to eq(:not_stale)
    ensure
      continue << true if touching&.alive?
      [touching, contender].compact.each { |thread| thread.join(1) }
    end

    it 'lets an alias-path lock take over a real-path lock left stale, and vice versa' do
      expect(real_lock.acquire).to be(true)
      lock_path = File.join(real_dir, 'extraction.lock')
      File.utime(Time.now - 7200, Time.now - 7200, lock_path)
      stale_alias_lock = described_class.new(lock_dir: alias_dir, name: 'extraction', stale_timeout: 60)

      expect(stale_alias_lock.acquire).to be(true)
      expect(File.exist?(lock_path)).to be(true)

      File.utime(Time.now - 7200, Time.now - 7200, lock_path)
      stale_real_lock = described_class.new(lock_dir: real_dir, name: 'extraction', stale_timeout: 60)

      expect(stale_real_lock.acquire).to be(true)
    end
  end

  describe 'concurrent acquisition' do
    it 'only allows one thread to acquire the lock' do
      results = []
      mutex = Mutex.new
      barrier = Queue.new

      thread_count = 10
      threads = thread_count.times.map do
        Thread.new do
          l = described_class.new(lock_dir: lock_dir, name: 'extraction')
          acquired = l.acquire
          mutex.synchronize { results << acquired }
          if acquired
            # Wait until all other threads have recorded their results
            barrier.pop
            l.release
          end
        end
      end

      # Poll until all threads have reported results
      poll_until(timeout: 5) { mutex.synchronize { results.size == thread_count } }
      barrier.push(:release)
      threads.each(&:join)

      # Exactly one thread should have acquired the lock
      expect(results.count(true)).to eq(1)
    end
  end

  # `touch` gated on `locked?` — `@held && File.exist?` — which stays true after
  # a contender retires us and puts its own lock at the same path. A retired
  # holder then refreshed the SUCCESSOR's mtime, so if that successor crashed,
  # its lock never aged out while the retired process lived and every writer was
  # blocked until it exited.
  #
  # Being retired mid-run is the exact scenario a heartbeat exists to prevent,
  # so it is also the state a heartbeat is most likely to find itself in when it
  # fails to.
  describe '#touch ownership' do
    let(:lock_dir) { Dir.mktmpdir('woods_touch_own') }

    after { FileUtils.rm_rf(lock_dir) }

    def build(stale_timeout: 0.2)
      described_class.new(lock_dir: lock_dir, name: 'extraction', stale_timeout: stale_timeout)
    end

    it 'refuses to refresh a lock a contender has taken over' do
      holder = build
      holder.acquire
      sleep 0.3
      expect(build.acquire).to be true

      expect(holder.touch).to be false
    end

    it 'does not move the successor mtime' do
      holder = build
      holder.acquire
      sleep 0.3
      build.acquire
      before = File.mtime(File.join(lock_dir, 'extraction.lock'))
      sleep 0.05

      holder.touch

      expect(File.mtime(File.join(lock_dir, 'extraction.lock'))).to eq(before)
    end

    it 'stops believing it holds the lock once it learns otherwise' do
      holder = build
      holder.acquire
      sleep 0.3
      build.acquire

      holder.touch

      expect(holder.locked?).to be false
    end

    it 'still refreshes for the live holder' do
      holder = build(stale_timeout: 5)
      holder.acquire

      expect(holder.touch).to be true
    end

    # A hardening commit introduced this: `touch` cleared @held whenever it
    # could not prove ownership, and `release` opens with `return unless @held`,
    # so a lock that was genuinely ours but unreadable was never cleaned up and
    # every writer blocked for the full stale window. "I cannot prove this is
    # mine" is not "this is not mine".
    it 'refuses to refresh an unreadable lock without disowning it' do
      holder = build(stale_timeout: 600)
      holder.acquire
      File.write(File.join(lock_dir, 'extraction.lock'), '{"pid":123,"tok')

      expect(holder.touch).to be false
      expect(holder.locked?).to be true
    end

    it 'still releases an unreadable lock it holds' do
      holder = build(stale_timeout: 600)
      holder.acquire
      path = File.join(lock_dir, 'extraction.lock')
      File.write(path, '{"pid":123,"tok')

      holder.touch
      holder.release

      expect(File.exist?(path)).to be false
    end

    it 'refuses after its own release' do
      holder = build(stale_timeout: 5)
      holder.acquire
      holder.release

      expect(holder.touch).to be false
    end

    # `touch` used to refresh via FileUtils.touch, which CREATES a missing
    # file. A heartbeat racing a release could read :ours, lose the file to
    # the release's rename+delete, and then recreate an empty 0-byte lock no
    # process owns and no release will ever delete — every writer blocked for
    # the full stale window.
    describe 'a lock that vanishes' do
      let(:lock_path) { File.join(lock_dir, 'extraction.lock') }

      it 'does not recreate the file after its own release removed it' do
        holder = build(stale_timeout: 600)
        holder.acquire
        holder.release

        expect(holder.touch).to be false
        expect(File.exist?(lock_path)).to be false
      end

      it 'does not recreate a lock deleted out from under it' do
        holder = build(stale_timeout: 600)
        holder.acquire
        FileUtils.rm_f(lock_path)

        expect(holder.touch).to be false
        expect(File.exist?(lock_path)).to be false
      end

      it 'does not recreate a lock that vanishes between the ownership read and the refresh' do
        holder = build(stale_timeout: 600)
        holder.acquire
        # Interleave the race deterministically: ownership reads :ours, then
        # the lock vanishes (a release racing this heartbeat) before the
        # refresh lands.
        allow(holder).to receive(:lock_ownership) do
          FileUtils.rm_f(lock_path)
          :ours
        end

        expect(holder.touch).to be false
        expect(File.exist?(lock_path)).to be false
      end
    end
  end
end
