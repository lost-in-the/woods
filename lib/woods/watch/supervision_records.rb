# frozen_string_literal: true

module Woods
  module Watch
    # Bounded readers and liveness correlation for persisted supervision records.
    module SupervisionRecords
      # Read bounded records without granting signal or writer-lock authority.
      # @param index [String] published index root
      # @return [Hash] supervision records with separately evaluated liveness
      def self.read(index)
        directory = File.join(index, SupervisionStatus::DIRECTORY)
        return { records: [] } unless readable_directory?(directory)

        names = Dir.each_child(directory).take(SupervisionStatus::MAX_SCAN + 1)
        records = names.first(SupervisionStatus::MAX_SCAN).filter_map do |name|
          read_record(File.join(directory, name)) if /\A[a-f0-9]{32}\.json\z/.match?(name)
        end
        records.sort_by! { |record| [record['alive'] ? 0 : 1, -Time.iso8601(record['updated_at']).to_f] }
        correlate(records.first(SupervisionStatus::MAX_RECORDS), index)
        truncated = names.size > SupervisionStatus::MAX_SCAN || records.size > SupervisionStatus::MAX_RECORDS
        { records: records.first(SupervisionStatus::MAX_RECORDS), truncated: truncated }
      rescue SystemCallError
        { records: [] }
      end

      def self.readable_directory?(directory)
        File.directory?(directory) && !File.symlink?(directory)
      end
      private_class_method :readable_directory?

      def self.read_record(path)
        bytes = bounded_read(path)
        return unless bytes

        record = JSON.parse(bytes)
        return unless valid_record?(record, path)

        age = Time.now - Time.iso8601(record['updated_at'])
        record['alive'] = record['state'] != 'stopped' &&
                          age.between?(-30, SupervisionStatus::STALE_AFTER) && local_alive?(record)
        record
      rescue SystemCallError, JSON::ParserError, TypeError, ArgumentError
        nil
      end
      private_class_method :read_record

      def self.bounded_read(path)
        return if File.symlink?(path)

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        bytes = File.open(path, flags) { |file| file.read(SupervisionStatus::MAX_BYTES + 1) if file.stat.file? }
        bytes if bytes && bytes.bytesize <= SupervisionStatus::MAX_BYTES
      end
      private_class_method :bounded_read

      def self.valid_record?(record, path)
        record.is_a?(Hash) && record['version'] == 1 && record['launcher'] == File.basename(path, '.json') &&
          SupervisionStatus::STATES.include?(record['state'])
      end
      private_class_method :valid_record?

      def self.local_alive?(record)
        unless record['host'] == Status.host_identity && record['pid'].is_a?(Integer) && record['pid'].positive?
          return false
        end

        Process.kill(0, record['pid'])
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
      private_class_method :local_alive?

      def self.correlate(records, index)
        status = Status.new(output_dir: index)
        daemon = status.read
        daemon_alive = daemon.is_a?(Hash) && status.alive?
        records.each do |record|
          record['active_child'] = daemon_alive && matches_child?(record, daemon)
        end
      rescue SystemCallError, TypeError, NoMethodError
        records.each { |record| record['active_child'] = false }
      end
      private_class_method :correlate

      def self.matches_child?(record, daemon)
        record['alive'] && record['child_pid'] == daemon['pid'] && record['host'] == daemon['host']
      end
      private_class_method :matches_child?
    end
  end
end
