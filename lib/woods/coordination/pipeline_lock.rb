# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'

# Woods::Error is defined in the entry point; required here so this file can
# be loaded directly (the watch daemon reaches for it without loading the
# whole gem first).
require 'woods'
require 'woods/watch/status'
require 'woods/coordination/liveness'

module Woods
  module Coordination
    class LockError < Woods::Error; end

    # Raised by {PipelineLock#fenced} when this instance no longer owns the
    # lock: another writer took it over after its lease expired. The work the
    # fence guards (promoting a payload, publishing the marker, pruning) did
    # not happen.
    class LockLostError < LockError; end

    # File-based lock for preventing concurrent pipeline operations.
    #
    # Creates a lock file with PID, host and timestamp. A lock is stale when
    # it is older than the stale timeout, or when it was written on this host
    # by a process that no longer exists (a holder killed mid-run).
    #
    # @example
    #   lock = PipelineLock.new(lock_dir: '/tmp', name: 'extraction')
    #   lock.with_lock do
    #     # extraction runs here
    #   end
    #
    class PipelineLock
      DEFAULT_STALE_TIMEOUT = 3600 # 1 hour

      # The lock every writer of one index serializes on: `woods:extract`,
      # `woods:incremental`, `woods:refresh`, the watch daemon, the MCP
      # operator tools and `woods_reload`. Its name and stale window live here,
      # beside {.for_index}, so no writer can build a lock the others do not
      # contend with.
      INDEX_WRITER_NAME = 'extraction'

      # A daemon cycle is milliseconds; a manual full extraction is seconds to
      # minutes, and a healthy holder heartbeats ({LockHeartbeat}). This bounds
      # how long a crashed writer can block the others.
      INDEX_WRITER_STALE_TIMEOUT = 600

      # The writer lock for the index published in +output_dir+.
      #
      # @param output_dir [String, Pathname] the index directory the writer
      #   publishes into; the lock lives inside it
      # @return [PipelineLock]
      def self.for_index(output_dir)
        new(lock_dir: output_dir.to_s, name: INDEX_WRITER_NAME, stale_timeout: INDEX_WRITER_STALE_TIMEOUT)
      end

      @held_locks = {}
      @held_locks_mutex = Mutex.new

      # The index writer lock this process currently holds for +output_dir+,
      # if any.
      #
      # A writer holds its lock around the whole run, but the publish step
      # deep inside {Woods::Extractor} is where ownership has to be proven, and
      # every caller (rake tasks, the watch daemon, the MCP operator tools,
      # {Woods.extract!}) builds its extractor separately from its lock. A lock
      # registers itself here when {#acquire} succeeds and leaves on
      # {#release}, so the extractor finds it without each caller threading it
      # through. A taken-over instance stays registered until it is released:
      # it must still be found, so that {#fenced} can refuse it.
      #
      # @param output_dir [String, Pathname]
      # @return [PipelineLock, nil]
      def self.held_for_index(output_dir)
        key = registry_key(output_dir, INDEX_WRITER_NAME)
        @held_locks_mutex.synchronize { @held_locks[key]&.last }
      end

      # Kept as a list per directory: if one process ever holds two instances
      # (an obsolete one and its successor), releasing either leaves the other
      # findable, so the obsolete one is still fenced rather than forgotten.
      #
      # @api private
      def self.register_held(lock, key)
        @held_locks_mutex.synchronize do
          held = (@held_locks[key] ||= [])
          held << lock unless held.any? { |entry| entry.equal?(lock) }
        end
      end

      # @api private
      def self.unregister_held(lock, key)
        @held_locks_mutex.synchronize do
          held = @held_locks[key] or next
          held.reject! { |entry| entry.equal?(lock) }
          @held_locks.delete(key) if held.empty?
        end
      end

      # @return [Array(String, String)] the canonical directory and lock name
      def self.registry_key(dir, name)
        [File.realpath(dir.to_s), name]
      rescue SystemCallError
        [File.expand_path(dir.to_s), name]
      end

      # The transaction-guard filename for a lock of +name+, exposed so
      # cleanup code that empties a lock directory (woods:clean) can skip the
      # guard during its sweep — deleting a flock'd guard out from under a
      # contender's critical section would split the flock across two inodes.
      # The guard stays after cleanup and lock release: a new contender may
      # already be holding it before its lock file exists.
      #
      # @param name [String]
      # @return [String]
      def self.guard_filename(name)
        ".#{name}.lock.guard"
      end

      # @param lock_dir [String] Directory for lock files
      # @param name [String] Lock name (used as filename prefix)
      # @param stale_timeout [Integer] Seconds after which a lock is considered stale
      # The window after which an untouched lock is considered abandoned.
      # Exposed so a heartbeat paces itself from the lock it is refreshing
      # rather than from a constant that only happens to match.
      #
      # @return [Numeric]
      attr_reader :stale_timeout

      def initialize(lock_dir:, name:, stale_timeout: DEFAULT_STALE_TIMEOUT)
        @lock_dir = lock_dir
        @name = name
        @stale_timeout = stale_timeout
        @lock_path = File.join(lock_dir, "#{name}.lock")
        @held = false
      end

      # Attempt to acquire the lock.
      #
      # @return [Boolean] true if lock acquired, false if already held
      def acquire
        with_path_guard do
          if File.exist?(@lock_path)
            return false unless stale?
            # Retire the stale lock atomically. A bare rm_f + create here is
            # a TOCTOU race: two processes passing the stale check together
            # could each delete-and-create, the second deleting the first's
            # FRESH lock — both would then "hold" it.
            return false unless retire_stale_unlocked == :cleared
          end

          # Keep O_EXCL even though cooperating implementations hold the guard:
          # it still fails closed if an external writer creates the path.
          begin
            File.open(@lock_path, File::WRONLY | File::CREAT | File::EXCL) do |file|
              file.write(lock_content)
            end
          rescue Errno::EEXIST
            raise
          rescue ScriptError, StandardError
            discard_partial_lock
            raise
          end
          mark_held
          true
        end
      rescue Errno::EEXIST
        false
      end

      # The ownership token this instance wrote when it last acquired the
      # lock, or nil before any acquisition. Unique per acquisition, so a
      # writer can name things that only it may touch (its private payload
      # stage) after it.
      #
      # @return [String, nil]
      attr_reader :token

      # Run a block only while this instance provably owns the lock, under the
      # same guard every takeover takes.
      #
      # This is the fence for a writer's irreversible steps. A check of the
      # token followed by a separate rename leaves a window: the lease can
      # expire and another writer take over between the two. Here the token
      # check and the block both run inside the path guard, and {#acquire}
      # retires a stale lock only inside that guard too, so a takeover either
      # completes before the check (and the check fails) or waits until the
      # block has finished. An unreadable lock file is not proof of ownership
      # and fails closed.
      #
      # The block must not take this lock's guard again (flock does not
      # nest across file descriptions); a heartbeat {#touch} on another thread
      # simply waits for it.
      #
      # @yield the work that must not outlive ownership
      # @return [Object] the block's value
      # @raise [LockLostError] when the lock was taken over, released or lost
      def fenced
        with_path_guard do
          unless @held && lock_ownership == :ours
            raise LockLostError, "Lock '#{@name}' in #{@lock_dir} is no longer held by this writer " \
                                 '(its lease expired and another writer took over)'
          end

          yield
        end
      end

      # Retire the lock only when the file captured atomically from the public
      # lock path is genuinely stale.
      #
      # @return [Symbol] `:cleared`, `:not_stale`, or `:missing`
      def retire_stale
        return :missing unless File.directory?(@lock_dir)

        with_path_guard { retire_stale_unlocked }
      rescue Errno::ENOENT
        :missing
      end

      # Release the lock.
      #
      # Deletes the lock file only if it still carries this instance's
      # token — a run that outlived stale_timeout may have been
      # legitimately taken over, and deleting unconditionally would drop
      # the new holder's lock.
      #
      # @return [void]
      def release
        return unless @held

        with_path_guard do
          next unless @held

          # Clear @held before touching the ownership path so another thread
          # using this instance cannot begin a heartbeat behind this release.
          @held = false
          release_unlocked
        end
      rescue Errno::ENOENT
        nil
      ensure
        @held = false
        self.class.unregister_held(self, registry_key)
      end

      # Execute a block while holding the lock.
      #
      # @yield Block to execute
      # @return [Object] Return value of the block
      # @raise [LockError] if lock cannot be acquired
      def with_lock(&block)
        raise LockError, "Cannot acquire lock '#{@name}' — another process is running" unless acquire

        begin
          block.call
        ensure
          release
        end
      end

      # Who the lock file says holds it, for a waiting writer to report.
      #
      # @return [Hash, nil] +'pid'+, +'host'+ and +'locked_at'+ as recorded
      #   (any may be missing from a lock an older version wrote), or nil
      #   when there is no readable lock
      def holder
        record = JSON.parse(File.read(@lock_path))
        record.is_a?(Hash) ? record.slice('pid', 'host', 'locked_at') : nil
      rescue JSON::ParserError, SystemCallError, EncodingError
        nil
      end

      # Whether the lock is currently held by this instance.
      #
      # @return [Boolean]
      def locked?
        return false unless @held

        with_path_guard { @held && File.exist?(@lock_path) }
      rescue SystemCallError
        false
      end

      # Refresh the held lock's mtime so a long but healthy run is not mistaken
      # for a crashed one.
      #
      # Staleness is measured from mtime, and nothing was updating it while the
      # lock was held. A full extraction on a large host app can exceed
      # `stale_timeout`, at which point any contender retires the lock of a run
      # that is still going — producing exactly the two-writer clobber the lock
      # exists to prevent. A holder that outlives the window must therefore say
      # so periodically.
      #
      # No-op unless this instance holds the lock, so a caller can heartbeat
      # unconditionally.
      #
      # @return [Boolean] true when the mtime was refreshed
      def touch
        return false unless @held

        with_path_guard do
          next false unless @held && File.exist?(@lock_path)

          touch_unlocked?
        end
      rescue SystemCallError
        # The lock vanished (retired by a non-cooperating contender, or the
        # directory went away). The next acquire/release resolves it.
        false
      end

      private

      def registry_key
        @registry_key ||= self.class.registry_key(@lock_dir, @name)
      end

      # @return [void]
      def mark_held
        @held = true
        self.class.register_held(self, registry_key)
      end

      # Remove a lock file this {#acquire} call created but could not finish
      # writing (INF-7).
      #
      # A write that fails after the O_EXCL create — a full or read-only disk —
      # would otherwise leave a 0-byte lock: fresh (mtime now, so never stale),
      # unparseable (so {#lock_ownership} reads +:unknown+ for every process,
      # including this one), and never released because +@held+ was never set.
      # That artifact blocks every writer for the whole stale window; {#touch}
      # was already fixed never to create one.
      #
      # Safe unconditionally: O_EXCL proves *this* call created the path, and
      # the path guard is still held. Errors from the unlink itself are
      # swallowed so they cannot replace the real failure being re-raised.
      #
      # @return [void]
      def discard_partial_lock
        File.unlink(@lock_path)
      rescue SystemCallError
        nil
      end

      def with_path_guard
        # Ensure the lock directory itself exists — never its parent. A guard
        # that lived beside @lock_dir needed the parent writable too, which a
        # deployment that only grants write access to the lock directory
        # can't satisfy.
        FileUtils.mkdir_p(@lock_dir)
        File.open(guard_path, File::RDWR | File::CREAT, 0o600) do |guard|
          guard.flock(File::LOCK_EX)
          yield
        end
      end

      # The transaction guard, kept inside the owned lock directory so it
      # resolves through the same symlink the lock file itself does. A guard
      # computed from `File.expand_path(lock_dir)` split in two: expand_path
      # normalizes `.`/`..` but never dereferences a symlink, so a real path
      # and a symlinked alias of the same directory produced two different
      # sibling guard files — flocks that never contended, defeating every
      # TOCTOU protection `with_path_guard` exists to provide. Deriving the
      # guard from `File.realpath` and placing it inside the directory
      # resolves both aliases to the identical path, the same way `@lock_path`
      # already does implicitly by living inside `lock_dir`.
      #
      # Memoized: only the first caller (which has just ensured the directory
      # exists via `mkdir_p`) needs to resolve it; every later access reuses
      # that resolution rather than re-touching the filesystem.
      #
      # @return [String]
      def guard_path
        @guard_path ||= File.join(canonical_lock_dir, self.class.guard_filename(@name))
      end

      # @return [String] the lock directory's real path when it exists,
      #   falling back to a lexical expansion when it does not — realpath
      #   requires an existing path and callers must never be made to create
      #   one just to compute a guard location.
      def canonical_lock_dir
        File.realpath(@lock_dir)
      rescue Errno::ENOENT
        File.expand_path(@lock_dir)
      end

      # Atomically retire a stale lock file via rename. Rename is atomic on
      # POSIX: of any processes racing to take over the same stale lock,
      # exactly one rename succeeds; the losers get ENOENT and back off.
      # Winning the rename does NOT guarantee winning the lock — another
      # process may O_EXCL-create between our rename and our create, which
      # the caller's EEXIST rescue handles.
      #
      # Rename alone is not enough, though: a competitor that already passed
      # `stale?` on the SAME original file may have retired it and created a
      # FRESH lock before we run. Our rename would then move that fresh lock
      # aside — and both processes would "hold" the lock. So after winning
      # the rename we re-check the retired file's age; if it turns out to be
      # fresh (someone beat us to the takeover), we put it back and lose the
      # race instead of clobbering a live holder.
      #
      # @return [Symbol] `:cleared` when genuinely stale, `:not_stale` when a
      #   fresher successor was restored instead, `:missing` when the lock
      #   was already gone
      def retire_stale_unlocked
        graveyard = "#{@lock_path}.stale.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.rename(@lock_path, graveyard)

        unless stale_file?(graveyard)
          restore_lock_unlocked(graveyard)
          return :not_stale
        end

        FileUtils.rm_f(graveyard)
        :cleared
      rescue Errno::ENOENT
        :missing
      end

      def release_unlocked
        # Rename first, then inspect: a plain read-then-unlink is a TOCTOU —
        # after we read our own token a takeover could replace the file, and
        # our unlink would then delete the NEW holder's lock. Renaming
        # atomically captures whatever is at the path.
        graveyard = "#{@lock_path}.release.#{Process.pid}.#{SecureRandom.hex(4)}"
        begin
          File.rename(@lock_path, graveyard)
        rescue Errno::ENOENT
          return # already gone
        end

        if own_lock?(graveyard)
          FileUtils.rm_f(graveyard)
        else
          # We were legitimately taken over — put the successor's lock back
          # without clobbering a still-newer holder (see
          # {#restore_lock_unlocked}).
          restore_lock_unlocked(graveyard)
        end
      end

      def touch_unlocked?
        # Ownership, not just presence. `locked?` asks whether *a* lock file
        # exists and this instance thinks it holds one — which stays true after
        # a contender has retired us and put its own lock at the same path. A
        # retired holder would then refresh the **successor's** mtime, and if
        # that successor crashed its lock would never age out while the retired
        # process lived, blocking every writer until it exited.
        #
        # That is not hypothetical for a heartbeat: being retired mid-run is the
        # exact scenario a heartbeat exists to prevent, so it is also the state a
        # heartbeat is most likely to find itself in when it fails to.
        #
        # Clearing @held is the honest response — we do not hold it, and
        # continuing to believe we do would let `release` act on a lock that is
        # someone else's.
        case lock_ownership
        when :ours
          # Refresh with `File.utime`, never `FileUtils.touch`: touch CREATES a
          # missing file, and the lock can vanish between the ownership read
          # and the refresh — a heartbeat racing its own process's `release` is
          # the ordinary way. Recreating it leaves an empty 0-byte lock no
          # process owns and no release will delete, blocking every writer for
          # the full stale window. `utime` raises ENOENT instead, which the
          # rescue below turns into the same plain false as any other vanished
          # lock; the next acquire/release resolves it.
          now = Time.now
          File.utime(now, now, @lock_path)
          true
        when :foreign
          # Proven someone else's: stop believing we hold it, or `release` would
          # act on their lock.
          @held = false
          false
        else
          # Unreadable — a torn write, most likely. Refuse to refresh, but stay
          # the owner: "I cannot prove this is mine" is not "this is not mine",
          # and disowning it here would strand the file. `release` opens with
          # `return unless @held`, so a disowned lock is never cleaned up and
          # every writer blocks until the stale window expires.
          false
        end
      end

      # Check if the existing lock file is stale.
      #
      # @return [Boolean]
      def stale?
        return false unless File.exist?(@lock_path)

        age = Time.now - File.mtime(@lock_path)
        age > @stale_timeout || abandoned?(@lock_path)
      rescue Errno::ENOENT
        true
      end

      # Whether the lock at +path+ was written on this host by a process that
      # is gone: dead, or (on Linux) exited and waiting to be reaped.
      #
      # A holder killed mid-run (a container restart's grace period ending,
      # SIGKILL, an OOM kill) never releases its lock, and a fresh lock would
      # otherwise block every writer for the whole stale window. A container
      # whose PID 1 never reaps leaves that holder a zombie, which signal 0
      # still answers for.
      #
      # Only {Liveness.gone?} evidence takes over a fresh lock. Every other
      # answer leaves the lock to its age ({#stale?}): a live holder, and an
      # unknown one — a lock from another host, from a version that recorded
      # no host, without a usable pid, or whose holder answers EPERM with no
      # readable `/proc` status. A reused or shared hostname cannot establish
      # pid-namespace identity, the residual Watch::Status documents too; a
      # pid that has been reused by another process reads as alive, which
      # only delays the takeover.
      #
      # @param path [String]
      # @return [Boolean]
      def abandoned?(path)
        record = JSON.parse(File.read(path))
        return false unless record.is_a?(Hash)

        Liveness.gone?(holder_liveness(record))
      rescue JSON::ParserError, SystemCallError, EncodingError
        false
      end

      # @param record [Hash] a parsed lock file
      # @return [Symbol] see {Liveness::STATES}
      def holder_liveness(record)
        Liveness.check(record['pid'], host: record['host'], local_host: Watch::Status.host_identity)
      end

      # Three-state, deliberately — a boolean here conflates the two states
      # that need different handling.
      #
      # `:unknown` is not `:foreign`. Both refuse a refresh, because touching a
      # lock we cannot prove is ours would extend a stranger's claim. Only
      # `:foreign` justifies disowning, because only that means someone else
      # holds it. Collapsing them made an unreadable-but-ours lock leak: `touch`
      # cleared `@held`, and `release` returns early on `@held`, so nothing ever
      # removed the file and every writer blocked for the full stale window.
      #
      # @return [Symbol] `:ours`, `:foreign`, or `:unknown`
      def lock_ownership
        JSON.parse(File.read(@lock_path))['token'] == @token ? :ours : :foreign
      rescue JSON::ParserError, SystemCallError
        :unknown
      end

      # Whether the lock file at +path+ carries this instance's token.
      #
      # @param path [String]
      # @return [Boolean] true when the token matches, or the file is corrupt
      #   (an unparseable lock we already renamed aside is treated as ours to
      #   discard rather than restore).
      def own_lock?(path)
        JSON.parse(File.read(path))['token'] == @token
      rescue JSON::ParserError
        true
      end

      # Put a lock file we renamed aside back at @lock_path WITHOUT clobbering
      # a lock another process may have O_EXCL-created in the meantime.
      # `File.link` is atomic and fails with EEXIST if @lock_path already
      # exists, so a newer holder always wins; the aside copy is discarded
      # either way. A plain `File.rename` back would overwrite that newer
      # holder's lock — reintroducing a double-hold.
      #
      # @param graveyard [String] path of the renamed-aside lock file
      # @return [void]
      def restore_lock_unlocked(graveyard)
        File.link(graveyard, @lock_path)
      rescue Errno::EEXIST
        # A newer holder already claimed the path — our copy is obsolete.
        nil
      ensure
        FileUtils.rm_f(graveyard)
      end

      # Whether the file at +path+ is older than the stale timeout, or was
      # abandoned by a holder on this host (see {#abandoned?}).
      #
      # @param path [String]
      # @return [Boolean]
      def stale_file?(path)
        Time.now - File.mtime(path) > @stale_timeout || abandoned?(path)
      rescue Errno::ENOENT
        false
      end

      # @return [String] Lock file content (JSON with PID, host, timestamp,
      #   and an ownership token release verifies before deleting)
      def lock_content
        @token = SecureRandom.hex(8)
        JSON.generate(pid: Process.pid, host: Watch::Status.host_identity, locked_at: Time.now.iso8601,
                      name: @name, token: @token)
      end
    end
  end
end
