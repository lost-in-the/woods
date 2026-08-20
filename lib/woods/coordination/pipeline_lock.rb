# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'

# Woods::Error is defined in the entry point; required here so this file can
# be loaded directly (the watch daemon reaches for it without loading the
# whole gem first).
require 'woods'

module Woods
  module Coordination
    class LockError < Woods::Error; end

    # File-based lock for preventing concurrent pipeline operations.
    #
    # Creates a lock file with PID and timestamp. Supports stale lock
    # detection for crashed processes.
    #
    # @example
    #   lock = PipelineLock.new(lock_dir: '/tmp', name: 'extraction')
    #   lock.with_lock do
    #     # extraction runs here
    #   end
    #
    class PipelineLock
      DEFAULT_STALE_TIMEOUT = 3600 # 1 hour

      # The transaction-guard filename for a lock of +name+, exposed so
      # cleanup code that empties a lock directory (woods:clean) can skip the
      # guard during its sweep — deleting a flock'd guard out from under a
      # contender's critical section would split the flock across two inodes —
      # and remove it only after the lock is released.
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
          File.open(@lock_path, File::WRONLY | File::CREAT | File::EXCL) do |file|
            file.write(lock_content)
          end
          @held = true
          true
        end
      rescue Errno::EEXIST
        false
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
          # without clobbering a still-newer holder (see {#restore_lock}).
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
        age > @stale_timeout
      rescue Errno::ENOENT
        true
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
      # @return [Boolean] true when a genuinely stale lock was retired
      def retire_stale_lock?
        retire_stale == :cleared
      end

      # Whether the lock file at +path+ carries this instance's token.
      #
      # @param path [String]
      # @return [Boolean] true when the token matches, or the file is corrupt
      #   (an unparseable lock we already renamed aside is treated as ours to
      #   discard rather than restore).
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
      def restore_lock(graveyard)
        with_path_guard { restore_lock_unlocked(graveyard) }
      end

      def restore_lock_unlocked(graveyard)
        File.link(graveyard, @lock_path)
      rescue Errno::EEXIST
        # A newer holder already claimed the path — our copy is obsolete.
        nil
      ensure
        FileUtils.rm_f(graveyard)
      end

      # Whether the file at +path+ is older than the stale timeout.
      #
      # @param path [String]
      # @return [Boolean]
      def stale_file?(path)
        Time.now - File.mtime(path) > @stale_timeout
      rescue Errno::ENOENT
        false
      end

      # @return [String] Lock file content (JSON with PID, timestamp, and
      #   an ownership token release verifies before deleting)
      def lock_content
        @token = SecureRandom.hex(8)
        JSON.generate(pid: Process.pid, locked_at: Time.now.iso8601, name: @name, token: @token)
      end
    end
  end
end
