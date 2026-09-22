# frozen_string_literal: true

require 'securerandom'
require_relative 'status'
require_relative 'supervision_records'

module Woods
  module Watch
    # Independent owner records: a parked duplicate cannot overwrite the
    # daemon heartbeat or make incremental hooks defer to an inactive writer.
    class SupervisionStatus
      DIRECTORY = 'watch_supervisors'
      MAX_RECORDS = 32
      MAX_SCAN = 256
      MAX_BYTES = 8192
      STALE_AFTER = 30
      STATES = %w[starting booting reconciling ready degraded retrying parked stopped].freeze
      FIELDS = %i[state reason attempt child_pid retry_at].freeze

      # @param index [String] application-resolved output directory
      # @param token [String] unguessable launcher identity
      def initialize(index:, token:)
        raise ArgumentError, 'invalid launcher token' unless /\A[a-f0-9]{32}\z/.match?(token)

        @token = token
        @directory = File.join(index, DIRECTORY)
        @path = File.join(@directory, "#{token}.json")
      end

      # @param fields [Hash] state, owned child, attempt and bounded reason
      # @return [void]
      def write(**fields)
        validate_fields!(fields)
        verify_ownership!
        data = { version: 1, launcher: @token, pid: Process.pid, host: Status.host_identity,
                 updated_at: Time.now.utc.iso8601 }.merge(fields)
        bytes = JSON.generate(data)
        raise ArgumentError, 'oversized supervision record' if bytes.bytesize > MAX_BYTES

        AtomicFile.write(@path, bytes, mode: 0o644)
        prune_stale
      end

      # @param index [String] published index root
      # @return [Hash] bounded supervision diagnostics
      def self.read(index)
        SupervisionRecords.read(index)
      end

      def self.read_record(path)
        SupervisionRecords.send(:read_record, path)
      end
      private_class_method :read_record

      def self.local_alive?(record)
        SupervisionRecords.send(:local_alive?, record)
      end
      private_class_method :local_alive?

      private

      def verify_ownership!
        raise ArgumentError, 'invalid supervision directory' if File.symlink?(@directory)
        return unless File.exist?(@path) || File.symlink?(@path)

        previous = self.class.send(:read_record, @path)
        return if previous && previous['pid'] == Process.pid && previous['host'] == Status.host_identity

        raise ArgumentError, 'supervision record belongs to another owner'
      end

      def validate_fields!(fields)
        valid = (fields.keys - FIELDS).empty? && STATES.include?(fields[:state]) &&
                fields[:reason].is_a?(String) && /\A[a-z_]{1,80}\z/.match?(fields[:reason]) &&
                fields[:attempt].is_a?(String) && /\A[a-f0-9]{32}\z/.match?(fields[:attempt])
        raise ArgumentError, 'invalid supervision fields' unless valid
      end

      def prune_stale
        records = self.class.read(File.dirname(@directory))[:records]
        records.each do |record|
          next unless expired?(record) && removable?(record)

          path = File.join(@directory, "#{record['launcher']}.json")
          current = self.class.send(:read_record, path)
          stored = record.except('active_child')
          File.unlink(path) if current == stored
        end
      rescue SystemCallError
        nil
      end

      def expired?(record)
        record['launcher'] != @token && !record['alive'] &&
          Time.now - Time.iso8601(record['updated_at']) > STALE_AFTER
      end

      def removable?(record)
        record['state'] == 'stopped' ||
          (record['host'] == Status.host_identity && !self.class.send(:local_alive?, record))
      end
    end
  end
end
