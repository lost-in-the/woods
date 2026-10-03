# frozen_string_literal: true

module Woods
  # Reads host-application source as UTF-8, whatever the process locale.
  #
  # A bare `File.read` tags its result with the process default external
  # encoding. Under a POSIX locale (`LANG=C`, the default in a plain container
  # image) that is US-ASCII, so a multibyte byte anywhere in a source file,
  # an em dash in a comment, makes the first regex or Prism call raise
  # "invalid byte sequence in US-ASCII". Extractors rescue per file, so the
  # unit was dropped without a trace.
  #
  # Ruby source is UTF-8 unless declared otherwise, so the read is pinned to
  # UTF-8. Bytes that are still not valid UTF-8 (a stray Latin-1 byte, almost
  # always in a comment or string) are scrubbed to U+FFFD: the unit survives
  # with one replaced character instead of being lost. This is the same
  # policy as {GemMapper} and {RubyAnalyzer}. Woods' own artifacts go through
  # {AtomicFile.read} instead.
  module SourceFile
    module_function

    # @param path [String, Pathname] host source file
    # @return [String] valid UTF-8 content
    # @raise [SystemCallError] when the file cannot be read, as File.read
    def read(path)
      source = File.read(path.to_s, encoding: Encoding::UTF_8)
      source.valid_encoding? ? source : source.scrub
    end

    # @param path [String, Pathname] host source file
    # @return [Array<String>] valid UTF-8 lines, each with its line ending
    # @raise [SystemCallError] when the file cannot be read, as File.readlines
    def readlines(path)
      read(path).lines
    end
  end
end
