# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'

module Woods
  module Hooks
    # Separate, bounded emitted-hint history; never touches refresh queue/leases.
    class ContextState
      MAX_BYTES = 131_072
      MAX_SESSIONS = 32
      MAX_HINTS = 32

      def initialize(output_dir)
        @file = File.join(output_dir, 'hook-context-state.json')
      end

      def emit(result)
        return yield unless suppressible?(result)

        key = Digest::SHA256.hexdigest(JSON.generate([result[:root], result[:session]]))
        open_regular("#{@file}.lock", File::RDWR | File::CREAT) do |lock|
          return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          state = read_state
          history = state.delete(key) || []
          return if history.include?(result[:identity])

          yield
          state[key] = (history + [result[:identity]]).last(MAX_HINTS)
          state.shift while state.size > MAX_SESSIONS
          write_state(state)
        end
      rescue SystemCallError, IOError
        # State contention/unavailability may skip an optional hint, never refresh.
        nil
      end

      private

      def suppressible?(result)
        result[:identity] && result[:session]
      end

      def open_regular(path, flags)
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags | File::NONBLOCK, 0o600) do |file|
          raise IOError unless file.stat.file?

          yield file
        end
      end

      def read_state
        open_regular(@file, File::RDONLY) do |file|
          return {} if file.stat.size > MAX_BYTES

          state = JSON.parse(file.read(MAX_BYTES + 1))
          return {} unless valid_state?(state)

          state
        end
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      def valid_state?(state)
        state.is_a?(Hash) && state.size <= MAX_SESSIONS && state.all? do |key, history|
          digest?(key) && valid_history?(history)
        end
      end

      def valid_history?(history)
        history.is_a?(Array) && history.size <= MAX_HINTS && history.all? { |id| digest?(id) }
      end

      def digest?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end

      def write_state(state)
        temporary = "#{@file}.tmp-#{SecureRandom.hex(12)}"
        owned = nil
        open_regular(temporary, File::WRONLY | File::CREAT | File::EXCL) do |file|
          owned = file.stat
          file.write(JSON.generate(state))
        end
        File.rename(temporary, @file)
      ensure
        remove_owned_temporary(temporary, owned) if owned
      end

      def remove_owned_temporary(path, owned)
        current = File.lstat(path)
        File.unlink(path) if current.dev == owned.dev && current.ino == owned.ino
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
