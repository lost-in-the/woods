# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'tempfile'
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
    # lock serializes cooperating writers; hardlink publication never overwrites.
    class Store
      class Error < IOError; end

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

      def publish_new(destination, json)
        Dir.mkdir(destination.dirname, 0o700)
        begin
          publish(destination, json)
        rescue StandardError
          discard_empty(destination.dirname)
          raise
        end
      end

      def discard_empty(directory)
        Dir.rmdir(directory)
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOENT
        # Preserve nonempty evidence; cleanup is only for this call's empty directory.
        nil
      end

      def publish(destination, json)
        temporary = Tempfile.new('.impact-', destination.dirname)
        temporary.binmode
        temporary.chmod(0o600)
        temporary.write(json)
        temporary.flush
        temporary.fsync
        temporary.close
        File.link(temporary.path, destination)
        AtomicFile.fsync_directory(destination.dirname)
        AtomicFile.fsync_directory(destination.dirname.parent)
      ensure
        temporary&.close!
      end
    end
  end
end
