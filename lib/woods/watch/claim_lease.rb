# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'shellwords'

module Woods
  module Watch
    # The daemon, not its launcher, holds this descriptor for its whole run.
    # Sidecar inodes are permanent: unlinking a locked file defeats flock.
    #
    # A claim names its lease by the random id written inside the lease file,
    # never by device and inode: on a bind mount those numbers are not stable
    # across mount sessions or between a container and the host. A recreated
    # lease carries another id or none, so a lock taken on it cannot pass for
    # the owner's.
    class ClaimLease # rubocop:disable Metrics/ClassLength -- one lease's lock, id and recovery refusals stay together
      class Unavailable < StandardError; end
      CLAIM = 'watch_claim.json'
      MAX_BYTES = 4096
      LEASE_ID = /\A([a-f0-9]{32})\n\z/
      LEASE_ID_BYTES = 33
      MANUAL_RECOVERY = 'Manual claim recovery'
      MANUAL_STEP = 'confirm every watcher writing this index has stopped (check each host and container), ' \
                    "then follow \"#{MANUAL_RECOVERY}\" in docs/WATCH_DAEMON.md".freeze
      NEW_DIRECTORY = 'Starting over in a new output directory'
      SIDECAR_STEP = 'confirm every watcher writing this index has stopped (check each host and container), ' \
                     'never replace a sidecar while any writer may exist, ' \
                     "then follow \"#{NEW_DIRECTORY}\" in docs/WATCH_DAEMON.md".freeze

      attr_reader :token

      # @param index [String] index directory
      # @return [String] the recovery command, naming where the token lives without printing it
      def self.recovery_command(index)
        claim = File.join(index, CLAIM)
        "woods-watch --recover-claim #{Shellwords.escape(index)} --claim-token <token from #{claim}>"
      end

      # @param index [String] index directory
      # @return [Hash, nil] the claim's recorded `host` and `pid`, never its token
      def self.owner(index)
        record = JSON.parse(new(index).snapshot)
        return unless record.is_a?(Hash) && record['host'].is_a?(String) && record['pid'].is_a?(Integer)

        { 'host' => record['host'].gsub(/[^[:print:]]/, '?')[0, 255], 'pid' => record['pid'] }
      rescue JSON::ParserError, SystemCallError, Unavailable, EncodingError, ArgumentError
        nil
      end

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

      # A starting daemon writes a fresh id over anything short of a complete
      # one, in place and before any claim can name it: an interrupted write
      # and a lease from a release that wrote none both read as no id.
      # @param create [Boolean] only a new daemon creates the lease or writes its id
      # @return [void]
      def acquire(create: true)
        @lease = open_lock("#{CLAIM}.lease", create: create)
        @lease_id = read_lease_id
        @lease_id ||= write_lease_id if create
      rescue StandardError
        close
        raise
      end

      # @return [Hash] identity bound to the id inside this locked lease
      def fields
        { lease_version: 2, token: token, lease_id: @lease_id }
      end

      # @param record [Hash] parsed claim
      # @return [Boolean] false only for a v2 claim naming an id this lease does not hold
      def names_this_lease?(record)
        record['lease_version'] != 2 || (!@lease_id.nil? && record['lease_id'] == @lease_id)
      end

      def close
        @lease&.close
        @lease = nil
        @lease_id = nil
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
        unless valid_token?(token)
          raise Unavailable, 'claim token must be 64 hexadecimal characters; ' \
                             "copy \"token\" from #{File.join(@index, CLAIM)}"
        end

        coordinate do
          snapshot = read_selected_claim
          record = validate_claim(snapshot, token)
          acquire_recovery_lease
          verify_lease(record)
          unless read_claim == snapshot
            raise Unavailable, 'claim changed during recovery; inspect its current owner in ' \
                               "#{File.join(@index, CLAIM)} before choosing any token"
          end

          File.unlink(File.join(@index, CLAIM))
        end
      rescue SystemCallError => e
        raise Unavailable, "claim files are not usable here (#{e.class}); run recovery inside the environment " \
                           'that writes this index, as the user that owns its sidecars'
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
          unless name.end_with?('.lease')
            raise Unavailable, 'claim coordination is busy; another start or recovery is running: retry shortly'
          end

          raise Unavailable, 'owner lease is held; a live process still owns this index: ' \
                             'stop that owner through its supervisor and retry'
        end
        verify_regular_path(file, path)
        file
      rescue StandardError
        file&.close
        raise
      end

      # @param file [File] opened sidecar
      # @param path [String] unchanged regular path on disk
      # @param step [String] where to send the reader: a bad sidecar blocks startup, a bad claim does not
      def verify_regular_path(file, path, step: SIDECAR_STEP)
        opened = file.stat
        current = File.lstat(path)
        return if opened.file? && current.file? && [opened.dev, opened.ino] == [current.dev, current.ino]

        raise Unavailable, "claim sidecar must be an unchanged regular file; #{step}"
      end

      # @return [String, nil] the complete id read through the locked descriptor
      def read_lease_id
        @lease.pread(LEASE_ID_BYTES + 1, 0)[LEASE_ID, 1]
      rescue EOFError
        nil
      end

      def write_lease_id
        id = SecureRandom.hex(16)
        @lease.truncate(0)
        @lease.pwrite("#{id}\n", 0)
        @lease.fsync
        id
      end

      def acquire_recovery_lease
        acquire(create: false)
      rescue Errno::ENOENT
        raise Unavailable, "owner lease is missing; #{MANUAL_STEP}"
      rescue Errno::ELOOP, Errno::EISDIR
        raise Unavailable, "owner lease is not a regular file; #{SIDECAR_STEP}"
      end

      def read_selected_claim
        read_claim
      rescue Errno::ENOENT
        raise Unavailable, "no claim at #{File.join(@index, CLAIM)}; nothing to recover: start the normal owner"
      rescue Errno::ELOOP
        raise Unavailable, "claim must be a regular file; #{MANUAL_STEP}"
      end

      def read_claim
        path = File.join(@index, CLAIM)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          verify_regular_path(file, path, step: MANUAL_STEP)
          bytes = file.read(MAX_BYTES + 1)
          raise Unavailable, "claim exceeds the recovery size limit; #{MANUAL_STEP}" if bytes.bytesize > MAX_BYTES

          bytes
        end
      end

      def validate_claim(snapshot, token)
        record = JSON.parse(snapshot)
        raise Unavailable, "legacy or unverifiable claim; #{MANUAL_STEP}" unless valid_record?(record)
        unless record['token'] == token
          raise Unavailable, 'claim token changed; another owner claimed this index since that token was copied: ' \
                             "inspect the host and pid in #{File.join(@index, CLAIM)} before retrying"
        end

        record
      rescue JSON::ParserError
        raise Unavailable, "legacy or unverifiable claim; #{MANUAL_STEP}"
      end

      def valid_record?(record)
        record.is_a?(Hash) && valid_token?(record['token']) &&
          record['pid'].is_a?(Integer) && record['pid'].positive? && record['host'].is_a?(String) &&
          known_lease_version?(record)
      end

      def known_lease_version?(record)
        record['lease_version'] == 1 || (record['lease_version'] == 2 && valid_lease_id?(record['lease_id']))
      end

      # A v1 claim recorded device and inode as its writer's mount view numbered
      # them, so a mismatch proves nothing; the lease lock already held here is
      # what excludes a live owner. A v2 claim must name the id inside it.
      def verify_lease(record)
        return if names_this_lease?(record)

        raise Unavailable, 'owner lease was replaced since this claim was written, ' \
                           "so ownership cannot be verified; #{MANUAL_STEP}"
      end

      def valid_lease_id?(value)
        value.is_a?(String) && value.match?(/\A[a-f0-9]{32}\z/)
      end

      def valid_token?(value)
        value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
      end
    end
  end
end
