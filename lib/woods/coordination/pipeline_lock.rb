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
        FileUtils.mkdir_p(@lock_dir)

        if File.exist?(@lock_path)
          return false unless stale?
          # Retire the stale lock atomically. A bare rm_f + create here is
          # a TOCTOU race: two processes passing the stale check together
          # could each delete-and-create, the second deleting the first's
          # FRESH lock — both would then "hold" it.
          return false unless retire_stale_lock
        end

        # Atomic lock creation: File::EXCL ensures this fails if file already exists
        File.open(@lock_path, File::WRONLY | File::CREAT | File::EXCL) do |f|
          f.write(lock_content)
        end
        @held = true
        true
      rescue Errno::EEXIST
        false
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

        # Clear @held up front so no later failure can leave this instance
        # believing it still holds the lock.
        @held = false

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
          restore_lock(graveyard)
        end
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
        @held && File.exist?(@lock_path)
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
        return false unless locked?

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
        unless touchable?
          @held = false
          return false
        end

        FileUtils.touch(@lock_path)
        true
      rescue SystemCallError
        # The lock vanished (retired by a contender, or the dir went away).
        # Nothing useful to do here; the next acquire/release resolves it.
        false
      end

      private

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
      # @return [Boolean] true if this process retired a genuinely stale lock
      def retire_stale_lock
        graveyard = "#{@lock_path}.stale.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.rename(@lock_path, graveyard)

        unless stale_file?(graveyard)
          # We grabbed a lock that is no longer stale — a competitor already
          # took over. Restore it (without clobbering a still-newer holder)
          # and back off.
          restore_lock(graveyard)
          return false
        end

        FileUtils.rm_f(graveyard)
        true
      rescue Errno::ENOENT
        false
      end

      # Whether the lock file at +path+ carries this instance's token.
      #
      # @param path [String]
      # @return [Boolean] true when the token matches, or the file is corrupt
      #   (an unparseable lock we already renamed aside is treated as ours to
      #   discard rather than restore).
      # Can this instance prove the lock at @lock_path is its own?
      #
      # Deliberately stricter than {#own_lock?}, which treats an unparseable
      # lock as ours so `release` still cleans up a corrupt file it renamed
      # aside. Refreshing is the opposite situation: a lock we cannot read is
      # one we cannot prove we hold, and touching it would extend a stranger's
      # claim. Not proving it means we stop, which is the safe direction.
      #
      # @return [Boolean]
      def touchable?
        JSON.parse(File.read(@lock_path))['token'] == @token
      rescue JSON::ParserError, SystemCallError
        false
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
