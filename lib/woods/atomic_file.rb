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
    # @param path [String, Pathname] destination path
    # @param content [String] file content
    # @return [void]
    def write(path, content)
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
      File.rename(tmp.path, path)
    rescue StandardError
      tmp&.close
      tmp&.unlink
      raise
    end
  end
end
