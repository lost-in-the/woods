# frozen_string_literal: true

require 'fileutils'
require 'json'

module CodebaseIndex
  module Coordination
    class LockError < CodebaseIndex::Error; end

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

          # Remove stale lock
          FileUtils.rm_f(@lock_path)
        end

        # Write lock file atomically
        File.write(@lock_path, lock_content)
        @held = true
        true
      rescue Errno::EEXIST
        false
      end

      # Release the lock.
      #
      # @return [void]
      def release
        FileUtils.rm_f(@lock_path) if @held
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
        @held && File.exist?(@lock_path)
      end

      private

      # Check if the existing lock file is stale.
      #
      # @return [Boolean]
      def stale?
        return false unless File.exist?(@lock_path)

        age = Time.now - File.mtime(@lock_path)
        age > @stale_timeout
      end

      # @return [String] Lock file content (JSON with PID and timestamp)
      def lock_content
        JSON.generate(pid: Process.pid, locked_at: Time.now.iso8601, name: @name)
      end
    end
  end
end
