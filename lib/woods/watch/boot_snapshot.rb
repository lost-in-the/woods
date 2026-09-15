# frozen_string_literal: true

require_relative '../reload_policy'
require_relative 'tree_scan'
require_relative 'watcher'

module Woods
  module Watch
    # Files observed before the watch task invokes Rails' environment task.
    # This bounds environment initialization, not earlier Bundler/application
    # loading. Hosts embedding the daemon may provide the same explicit boundary.
    class BootSnapshot
      def initialize(root:, policy: ReloadPolicy.new)
        @root = File.expand_path(root.to_s)
        @policy = policy
        @files = scan
      end

      # True for unchanged files, including a carried path absent before and
      # after boot. A deleted initializer must not demand another restart.
      def covers?(path)
        absolute = File.expand_path(path, @root)
        @files[absolute] == fingerprint(absolute)
      end

      # Includes additions and deletions, even if another writer has advanced
      # the index watermark while Rails was booting.
      def changed_paths
        current = scan
        (@files.keys | current.keys).reject { |path| @files[path] == current[path] }
      end

      private

      def scan
        TreeScan.files(root: @root, ignored: Watcher::DEFAULT_IGNORED_DIRECTORIES).each_with_object({}) do |path, files|
          next unless %i[restart reload].include?(@policy.classify(path.delete_prefix("#{@root}/")))

          stamp = fingerprint(path)
          files[path] = stamp if stamp
        end
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
