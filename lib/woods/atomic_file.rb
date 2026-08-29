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
    # @param path [String, Pathname] destination path
    # @param content [String] file content
    # @param mode [Integer] permissions for the written file (default 0600)
    # @return [void]
    def write(path, content, mode: 0o600)
      path = path.to_s
      FileUtils.mkdir_p(File.dirname(path))
      tmp = Tempfile.new('.woods-', File.dirname(path))
      # Binary mode so the content's bytes (e.g. UTF-8) are written verbatim
      # regardless of the process's default external encoding.
      tmp.binmode
      tmp.write(content)
      tmp.flush
      tmp.fsync
      tmp.close
      # Chmod the temp file so the destination is born with its final
      # permissions — never observed more open or more closed in between.
      File.chmod(mode, tmp.path)
      File.rename(tmp.path, path)
      fsync_directory(File.dirname(path))
    rescue StandardError
      tmp&.close
      tmp&.unlink
      raise
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
