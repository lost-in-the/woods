# frozen_string_literal: true

require 'digest'
require 'set'
require_relative '../reload_policy'
require_relative 'tree_scan'
require_relative 'watcher'

module Woods
  module Watch
    # Files observed before the watch task invokes Rails' environment task.
    # This bounds environment initialization, not earlier Bundler/application
    # loading. Hosts embedding the daemon may provide the same explicit boundary.
    #
    # Boot inputs (restart triggers and config Ruby) also keep a digest of
    # their bytes, so once the boot has finished, rewriting one with the same
    # bytes (a schema dump that changed nothing, a stash round trip) is still
    # covered by the boot. Reload inputs are judged by fingerprint only: their
    # bytes matching the boot says nothing about what the index last extracted.
    class BootSnapshot
      def initialize(root:, policy: ReloadPolicy.new)
        @root = File.expand_path(root.to_s)
        @policy = policy
        @files = scan
        @digests = @files.keys.filter_map { |path| [path, digest(path)] if boot_input?(path) }.to_h
        @verified = Set.new
      end

      # True for unchanged files, including a carried path absent before and
      # after boot. A deleted initializer must not demand another restart.
      def covers?(path)
        absolute = File.expand_path(path, @root)
        @files[absolute] == fingerprint(absolute) || same_bytes?(absolute)
      end

      # Record that the boot has finished. Bytes cover an input only when its
      # fingerprint was still the snapshot's at this moment: the boot read the
      # file at some point in between, so an input changed and restored while
      # it ran is never covered by its bytes.
      #
      # @return [void]
      def boot_finished!
        current = scan
        @verified = @files.keys.select { |path| @files[path] == current[path] }.to_set
      end

      # Includes additions and deletions, even if another writer has advanced
      # the index watermark while Rails was booting.
      def changed_paths
        current = scan
        (@files.keys | current.keys).reject { |path| @files[path] == current[path] || same_bytes?(path) }
      end

      private

      def scan
        TreeScan.files(root: @root, ignored: Watcher::DEFAULT_IGNORED_DIRECTORIES).each_with_object({}) do |path, files|
          relative = path.delete_prefix("#{@root}/")
          next unless %i[restart reload].include?(@policy.classify(relative)) || boot_helper?(relative)

          stamp = fingerprint(path)
          files[path] = stamp if stamp
        end
      end

      def boot_input?(path)
        relative = path.delete_prefix("#{@root}/")
        @policy.classify(relative) == :restart || boot_helper?(relative)
      end

      # A file absent at boot has no digest, so its later creation is a change.
      def same_bytes?(absolute)
        recorded = @digests[absolute]
        @verified.include?(absolute) && !recorded.nil? && recorded == digest(absolute)
      end

      # Config Ruby the policy ignores but the daemon restarts for when its
      # process loaded it at boot (F3). Fingerprinted so a supervisor restart
      # reconciles the change instead of exiting 75 over the same file forever.
      def boot_helper?(relative)
        relative.match?(%r{\Aconfig/.+\.rb\z})
      end

      def digest(path)
        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        nil
      end

      def fingerprint(path)
        stat = File.stat(path)
        [stat.ino, stat.size, stat.mtime, stat.ctime]
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end
  end
end
