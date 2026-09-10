# frozen_string_literal: true

require 'fileutils'
require 'tempfile'

module Woods
  # Crash-safe file writes via a temp file + atomic rename.
  #
  # Extracted from the pattern in {Woods::IndexArtifact} (whose own
  # +atomic_write+ is private and instance-level) so any component that writes
  # many files — e.g. the Obsidian exporter writing a vault of notes — can reuse
  # it. If the process dies mid-write, the destination file is either the old
  # content or the new content, never a torn partial.
  #
  # @example
  #   Woods::AtomicFile.write("tmp/woods/obsidian_vault/models/User.md", note_body)
  module AtomicFile
    module_function

    # Atomically write +content+ to +path+, creating parent directories.
    #
    # Permissions are explicit per artifact (O1): the default is the
    # restrictive 0600 Tempfile already uses, and only an artifact with a
    # documented cross-boundary consumer passes a wider mode (today exactly
    # one: the watch daemon's +watch_status.json+, read by host-side hooks
    # through a bind mount).
    #
    # +durable:+ chooses when the bytes are forced to the disk, never whether
    # the write is atomic. Both paths go tempfile, chmod, rename, so a reader
    # sees the old content or the new content and never a torn partial.
    # +durable: false+ drops the two forced flushes (the temp file's own
    # +fsync+ and the containing directory's), which is the whole cost of the
    # write on a journalling filesystem: roughly 8.9ms per file against
    # 0.11ms without, measured on btrfs.
    #
    # It is only safe for a file with no reader until something else commits
    # it. Woods' payload files qualify: every reader resolves through
    # +generation.json+, and that pointer is written durably after
    # {.sync_directory_tree} has flushed the payload it names. A file whose
    # readers do not go through the pointer (the watch daemon's status, the
    # update check's cache, an export, an embedding checkpoint) must stay
    # durable.
    #
    # @param path [String, Pathname] destination path
    # @param content [String] file content
    # @param mode [Integer] permissions for the written file (default 0600)
    # @param durable [Boolean] force the bytes to disk before returning
    #   (default true). Pass false only for a file that something else makes
    #   durable before any reader can resolve it.
    # @return [void]
    def write(path, content, mode: 0o600, durable: true)
      path = path.to_s
      FileUtils.mkdir_p(File.dirname(path))
      tmp = Tempfile.new('.woods-', File.dirname(path))
      # Binary mode so the content's bytes (e.g. UTF-8) are written verbatim
      # regardless of the process's default external encoding.
      tmp.binmode
      tmp.write(content)
      tmp.flush
      tmp.fsync if durable
      tmp.close
      # Chmod the temp file so the destination is born with its final
      # permissions — never observed more open or more closed in between.
      File.chmod(mode, tmp.path)
      File.rename(tmp.path, path)
      fsync_directory(File.dirname(path)) if durable
    rescue StandardError
      tmp&.close
      tmp&.unlink
      raise
    end

    # Make every file under +directory+ durable with one filesystem flush.
    #
    # The counterpart to {.write}'s +durable: false+. Thousands of per-file
    # +fsync+ calls and one +syncfs+ buy the same guarantee for a payload that
    # is published all at once, and cost 71.3s against 1.0s for 8000 files on
    # btrfs.
    #
    # Strategies, in order, first one that works wins:
    #
    # 1. +syncfs(2)+ on a descriptor for +directory+, through Fiddle. Linux
    #    only, and flushes exactly the one filesystem the payload is on.
    # 2. +sync -f <dir>+ (GNU coreutils), the same call through a subprocess.
    # 3. +sync+ with no arguments (BSD/macOS), which flushes everything
    #    mounted rather than one filesystem, but is still one call.
    # 4. an +fsync+ on every file and directory in the tree.
    #
    # The last resort is what keeps the guarantee honest: the chain never
    # silently does nothing, it only ever gets slower.
    #
    # Fiddle is a default gem through Ruby 3.4 and a bundled gem from 3.5, so
    # the require lives inside a rescue and Fiddle is deliberately not in the
    # gemspec. A host without it lands on +sync -f+.
    #
    # @param directory [String, Pathname] the tree to flush
    # @return [Symbol, nil] the strategy that ran (+:syncfs+, +:sync_f+,
    #   +:sync+, +:fsync_pass+), or nil when the directory does not exist
    def sync_directory_tree(directory)
      directory = directory.to_s
      return nil unless File.directory?(directory)

      strategy = syncfs(directory) || sync_f(directory) || plain_sync || fsync_pass(directory)
      log_sync_strategy(strategy, directory)
      strategy
    end

    # @return [Symbol, nil] +:syncfs+ when the libc call succeeded
    def syncfs(directory)
      call = syncfs_function
      return nil unless call

      succeeded = File.open(directory, File::RDONLY) { |dir| call.call(dir.fileno).zero? }
      succeeded ? :syncfs : nil
    rescue StandardError
      nil
    end

    # Resolved once per process, and nil for the whole process when it cannot
    # be. `dlopen` is not free, and a failed `require 'fiddle'` prints a
    # bundled-gem warning on every attempt from Ruby 3.5 onward — a publish
    # must not emit one line of noise per generation.
    #
    # @return [Fiddle::Function, nil]
    def syncfs_function
      return @syncfs_function if defined?(@syncfs_function)

      @syncfs_function = begin
        require 'fiddle'
        Fiddle::Function.new(Fiddle.dlopen(nil)['syncfs'], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      rescue LoadError, StandardError
        # No Fiddle in the bundle, no libc symbol (macOS has none), or the
        # handle would not open. `sync -f` is next in the chain.
        nil
      end
    end

    # @return [Symbol, nil] +:sync_f+ when `sync -f` exited 0
    def sync_f(directory)
      :sync_f if system('sync', '-f', directory, out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    # @return [Symbol, nil] +:sync+ when a bare `sync` exited 0
    def plain_sync
      :sync if system('sync', out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    # @return [Symbol] always +:fsync_pass+; this is the floor of the chain
    def fsync_pass(directory)
      Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).each do |entry|
        next if %w[. ..].include?(File.basename(entry))

        fsync_path(entry)
      end
      fsync_path(directory)
      :fsync_pass
    end

    # @param path [String] file or directory to flush
    # @return [void]
    def fsync_path(path)
      File.open(path, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EISDIR, Errno::ENOENT, Errno::EACCES
      nil
    end

    # @return [void]
    def log_sync_strategy(strategy, directory)
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Rails.logger.debug { "[Woods] payload sync via #{strategy} on #{directory}" }
    end

    def fsync_directory(directory)
      File.open(directory, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EISDIR
      nil
    end

    # Read a file Woods wrote, as UTF-8.
    #
    # The counterpart to {.write}, and not a nicety. {.write} goes through
    # `binmode` so the content's bytes land verbatim — but a plain `File.read`
    # tags what comes back with the process's *default external encoding*, and
    # a container with no locale set (`LANG=C`, the default in a plain Docker
    # image — precisely where the watch daemon is documented to run) makes that
    # US-ASCII. Any byte above 0x7F then raises
    # `Encoding::InvalidByteSequenceError` on the first `JSON.parse`.
    #
    # That is not hypothetical for Woods' own artifacts: the daemon writes
    # status reasons containing em dashes, so one ordinary lock contention
    # under `LANG=C` used to break `woods:watch_status`, the hook sync's
    # daemon-deference check and the `woods_status` tool until something
    # rewrote the file with an ASCII-only reason.
    #
    # @param path [String, Pathname] file to read
    # @return [String] UTF-8 content
    def read(path)
      File.read(path.to_s, encoding: Encoding::UTF_8)
    end
  end
end
