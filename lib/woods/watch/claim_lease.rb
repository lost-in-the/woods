# frozen_string_literal: true

require 'json'
require 'securerandom'

module Woods
  module Watch
    # The daemon, not its launcher, holds this descriptor for its whole run.
    # Sidecar inodes are permanent: unlinking a locked file defeats flock.
    class ClaimLease
      class Unavailable < StandardError; end
      CLAIM = 'watch_claim.json'
      MAX_BYTES = 4096

      attr_reader :token

      # @param index [String] existing index directory
      def initialize(index)
        @index = File.realpath(index)
        @token = SecureRandom.hex(32)
      end

      # @yield while serialized with daemon claim creation and retirement
      def coordinate
        lock = open_lock("#{CLAIM}.lock", create: true)
        yield
      ensure
        lock&.close
      end

      # @param create [Boolean] only a new daemon can create the permanent lease
      # @return [void]
      def acquire(create: true)
        @lease = open_lock("#{CLAIM}.lease", create: create)
      end

      # @return [Hash] identity bound to this exact locked inode
      def fields
        stat = @lease.stat
        { lease_version: 1, token: token, lease_device: stat.dev, lease_inode: stat.ino }
      end

      def close
        @lease&.close
        @lease = nil
      end

      # @return [String] bounded regular claim bytes, without following links
      def snapshot
        read_claim
      end

      # Refuse legacy records and re-check the selected claim while holding both
      # locks. Neither host names nor claim ages authorize this operation.
      # @param token [String] exact claim token selected by the operator
      # @return [void]
      def recover(token:)
        raise Unavailable, 'claim token must be 64 hexadecimal characters' unless valid_token?(token)

        coordinate do
          snapshot = read_claim
          record = validate_claim(snapshot, token)
          acquire(create: false)
          verify_lease(record)
          raise Unavailable, 'claim changed during recovery; inspect its current owner' unless read_claim == snapshot

          File.unlink(File.join(@index, CLAIM))
        end
      ensure
        close
      end

      private

      # @param name [String] fixed sidecar basename
      # @param create [Boolean] permit initial creation
      # @return [File] locked descriptor; never blocks on a live owner
      def open_lock(name, create:)
        flags = File::RDWR | File::NONBLOCK
        flags |= File::CREAT if create
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        path = File.join(@index, name)
        file = File.open(path, flags, 0o600) # rubocop:disable Style/FileOpen -- descriptor lifetime is ownership
        verify_regular_path(file, path)
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          label = name.end_with?('.lease') ? 'owner lease is held' : 'claim coordination is busy'
          raise Unavailable, "#{label}; stop the owner through its supervisor and retry"
        end
        verify_regular_path(file, path)
        file
      rescue StandardError
        file&.close
        raise
      end

      # @param file [File] opened sidecar
      # @param path [String] unchanged regular path on disk
      def verify_regular_path(file, path)
        opened = file.stat
        current = File.lstat(path)
        return if opened.file? && current.file? && [opened.dev, opened.ino] == [current.dev, current.ino]

        raise Unavailable, 'claim sidecar must be an unchanged regular file; do not replace lock files'
      end

      def read_claim
        path = File.join(@index, CLAIM)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          verify_regular_path(file, path)
          bytes = file.read(MAX_BYTES + 1)
          raise Unavailable, 'claim exceeds the recovery size limit' if bytes.bytesize > MAX_BYTES

          bytes
        end
      end

      def validate_claim(snapshot, token)
        record = JSON.parse(snapshot)
        unless valid_record?(record)
          raise Unavailable, 'legacy or unverifiable claim; use the documented legacy recovery procedure'
        end
        unless record['token'] == token
          raise Unavailable, 'claim token changed; inspect the current owner before retrying'
        end

        record
      rescue JSON::ParserError
        raise Unavailable, 'legacy or unverifiable claim; use the documented legacy recovery procedure'
      end

      def valid_record?(record)
        record.is_a?(Hash) && record['lease_version'] == 1 && valid_token?(record['token']) &&
          record['pid'].is_a?(Integer) && record['pid'].positive? && record['host'].is_a?(String)
      end

      def verify_lease(record)
        stat = @lease.stat
        return if record['lease_device'] == stat.dev && record['lease_inode'] == stat.ino

        raise Unavailable, 'owner lease inode changed; ownership cannot be verified'
      end

      def valid_token?(value)
        value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
      end
    end
  end
end
