# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'tempfile'
require 'tmpdir'
require_relative '../atomic_file'

module Woods
  module Impact
    # Exact saved-report bytes and their versioned envelope, without recomputation.
    module SavedReportValue
      # @param report [Report, String] report or its exact serialized JSON
      # @return [String] validated UTF-8 JSON, preserving every byte
      def self.serialize(report)
        json = report.is_a?(String) ? report.dup : report.to_json
        raise Store::Error, 'Impact report must serialize to JSON text' unless json.is_a?(String)

        json = json.dup.force_encoding(Encoding::UTF_8)
        raise Store::Error, 'Impact report JSON is not valid UTF-8' unless json.valid_encoding?

        data = JSON.parse(json)
        raise Store::Error, 'Unsupported saved impact report schema' unless valid?(data)

        json
      rescue JSON::ParserError
        raise Store::Error, 'Saved impact report JSON is invalid'
      end

      def self.valid?(data)
        data.is_a?(Hash) && data['schema_version'] == 1 && data['coverage'].is_a?(Hash) &&
          data['parameters'].is_a?(Hash) && %w[changed affected flows risks tests unknowns].all? do |key|
            data[key].is_a?(Array)
          end && envelope?(data)
      end

      def self.envelope?(data)
        return data['range'].is_a?(Hash) if data.dig('parameters', 'mode') == 'range'
        return false unless data.dig('parameters', 'mode') == 'focus'

        data['range'].nil? && data['endpoint'].is_a?(Hash) && data['focus'].is_a?(Array) && data['changed'] == []
      end
      private_class_method :valid?, :envelope?
    end

    # Guards every component beneath the caller-selected canonical index root.
    class StorePaths
      # @param index_dir [String, Pathname] existing index root, never a symlink
      def initialize(index_dir)
        root = Pathname.new(index_dir.to_s).expand_path
        raise Store::Error, 'Impact index root is unsafe or unavailable' unless root.directory? && !root.symlink?

        @root = root.realpath
        @directory = @root.join('explorer', 'impacts')
      end

      # @return [Pathname] saved-report namespace
      attr_reader :directory

      # @return [void] create only private, checked storage directories
      def prepare
        [@root.join('explorer'), @directory].each do |path|
          begin
            Dir.mkdir(path, 0o700)
            AtomicFile.fsync_directory(path.parent)
          rescue Errno::EEXIST
            # Existing directories are checked, never chmodded or replaced.
          end
          directory!(path)
        end
      end

      # @param id [String] exact lowercase SHA-256 ID
      # @return [Pathname] checked local path; no directory is created
      def path_for(id)
        raise Store::Error, 'Invalid saved impact report ID' unless id.is_a?(String) && id.match?(/\A[0-9a-f]{64}\z/)

        path = @root
        ['explorer', 'impacts', id].each do |part|
          path = path.join(part)
          directory!(path) if path.exist? || path.symlink?
        end
        path.join('impact.json')
      end

      # @param file [File] already opened with NOFOLLOW and NONBLOCK
      # @return [void] refuse nonregular or publicly accessible file descriptors
      def file!(file)
        stat = file.stat
        raise Store::Error, 'Unsafe saved impact file' unless stat.file? && stat.mode.nobits?(0o077)
      end

      private

      def directory!(path)
        stat = path.lstat
        return if stat.directory? && stat.mode.nobits?(0o077)

        raise Store::Error, 'Unsafe saved impact directory'
      end
    end

    # Content-addressed local reports, immutable after publication. A private
    # lock serializes cooperating writers. A report is written into a private
    # staging directory and renamed into place whole, so a writer that dies
    # leaves nothing at its report path; a staging directory or report
    # directory without its report found under the lock is a dead writer's
    # (an older writer created the directory first) and is removed.
    class Store
      class Error < IOError; end

      REPORT = 'impact.json'
      STAGING_PREFIX = '.staging-'
      TEMPORARY_PREFIX = '.impact-'

      # @param index_dir [String, Pathname] existing published index root
      def initialize(index_dir)
        @paths = StorePaths.new(index_dir)
      end

      # @param report [Report, String] report or exact serialized JSON
      # @return [String] SHA-256 ID; duplicate saves preserve the existing inode
      def save(report)
        json = SavedReportValue.serialize(report)
        id = Digest::SHA256.hexdigest(json)
        @paths.prepare
        with_lock do
          destination = path_for(id)
          discard_abandoned(destination.dirname)
          if destination.dirname.exist?
            raise Error, 'Conflicting saved impact report' unless read(id) == json
          else
            publish_new(destination, json)
          end
        end
        id
      rescue SystemCallError
        raise Error, 'Cannot publish saved impact report safely'
      end

      # @param id [String] exact lowercase SHA-256 ID
      # @return [String] exact verified JSON bytes, independent of payload retention
      def read(id)
        path = path_for(id)
        json = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          @paths.file!(file)
          file.binmode.read
        end
        raise Error, 'Saved impact report digest mismatch' unless Digest::SHA256.hexdigest(json) == id

        SavedReportValue.serialize(json)
      rescue SystemCallError
        raise Error, 'Saved impact report is unavailable or unsafe'
      end

      # @param id [String] saved-report ID
      # @return [Pathname] guarded local storage path; never persisted into JSON
      def path_for(id)
        @paths.path_for(id)
      end

      private

      def with_lock
        flags = File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK
        File.open(@paths.directory.join('.lock'), flags, 0o600) do |file|
          @paths.file!(file)
          file.flock(File::LOCK_EX)
          yield
        end
      end

      # Holding the lock proves no cooperating writer is mid-publication, so
      # every staging directory, and a report directory without its report,
      # belongs to a writer that died.
      def discard_abandoned(report_directory)
        @paths.directory.each_child do |entry|
          remove_leftover(entry, REPORT, TEMPORARY_PREFIX) if entry.basename.to_s.start_with?(STAGING_PREFIX)
        end
        report = report_directory.join(REPORT)
        return if !report_directory.exist? || report.symlink? || report.exist?

        remove_leftover(report_directory, TEMPORARY_PREFIX)
      end

      # Removes only a private directory of regular files a writer makes;
      # anything else is evidence to keep, and the save refuses.
      def remove_leftover(directory, *names)
        stat = directory.lstat
        entries = stat.directory? && !stat.symlink? ? directory.children : nil
        raise Error, 'Conflicting saved impact report' unless entries&.all? { |entry| leftover_file?(entry, names) }

        entries.each { |entry| File.unlink(entry) }
        Dir.rmdir(directory)
        AtomicFile.fsync_directory(directory.dirname)
      end

      def leftover_file?(entry, names)
        name = entry.basename.to_s
        entry.lstat.file? && names.any? { |prefix| name == prefix || name.start_with?(prefix) }
      end

      def publish_new(destination, json)
        staging = Pathname.new(Dir.mktmpdir(STAGING_PREFIX, @paths.directory.to_s))
        begin
          write_report(staging.join(REPORT), json)
          AtomicFile.fsync_directory(staging)
          File.rename(staging, destination.dirname)
        rescue StandardError
          discard_staging(staging)
          raise
        end
        AtomicFile.fsync_directory(destination.dirname.parent)
      end

      def discard_staging(staging)
        remove_leftover(staging, REPORT, TEMPORARY_PREFIX)
      rescue Errno::ENOENT
        # Already renamed into place: the published report stays.
        nil
      end

      def write_report(path, json)
        temporary = Tempfile.new(TEMPORARY_PREFIX, path.dirname)
        temporary.binmode
        temporary.chmod(0o600)
        temporary.write(json)
        temporary.flush
        temporary.fsync
        temporary.close
        File.link(temporary.path, path)
      ensure
        temporary&.close!
      end
    end
  end
end
