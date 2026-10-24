# frozen_string_literal: true

require_relative 'git_log'

module Woods
  # Per-file line counts and hunks for chosen commits (#804), from one `-U0`
  # patch walk over exactly those commits ({GitLog#patch_stream}). Each
  # file's hunks are `[start, length]` pairs in the commit's own coordinates,
  # old against the first parent and new in the commit, as git's hunk
  # headers give them. Binary files have no counts.
  class GitLineStats
    # One file of one commit.
    FileStats = Struct.new(:path, :additions, :deletions, :hunks, :more, keyword_init: true)

    DIFF = 'diff --git '.b
    HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/n
    ESCAPES = { 'a' => "\a", 'b' => "\b", 't' => "\t", 'n' => "\n", 'v' => "\v", 'f' => "\f", 'r' => "\r",
                '"' => '"', '\\' => '\\' }.freeze

    # @param root [String, Pathname] application root
    # @param hunks_per_file [Integer] hunks kept per file; the rest set `more`
    def initialize(root:, hunks_per_file:)
      @log = GitLog.new(root: root)
      @hunks_per_file = hunks_per_file
    end

    # @param shas [Array<String>]
    # @yieldparam sha [String]
    # @yieldparam stats [FileStats] path as repository-relative bytes
    # @return [void]
    # @raise [GitLog::ReadError] on an incomplete or malformed walk
    def each_file(shas, &block)
      return if shas.empty?

      @log.patch_stream(shas) { |io| parse(io, &block) }
    end

    # Undo git's C-style quoting of a path (`"a\tb"`, `"\303\251.rb"`).
    #
    # @param text [String] binary
    # @return [String] binary
    def self.unquote(text)
      return text unless text.length >= 2 && text.start_with?('"') && text.end_with?('"')

      text[1...-1].b.gsub(/\\([0-7]{3}|.)/n) do
        code = Regexp.last_match(1)
        code.length == 3 ? code.to_i(8).chr : ESCAPES.fetch(code, code).b
      end
    end

    private

    def parse(io, &block)
      state = { sha: nil, file: nil, body: false }
      while (line = io.gets)
        line = line.chomp
        if line.start_with?("\0") then start_commit(state, line, &block)
        elsif line.start_with?(DIFF) then start_file(state, line, &block)
        else record(state, line)
        end
      end
      flush(state, &block)
    end

    def start_commit(state, line, &block)
      flush(state, &block)
      state[:sha] = line.delete_prefix("\0")
      raise GitLog::ReadError, 'malformed patch commit header' unless state[:sha].match?(GitLog::SHA)
    end

    def start_file(state, line, &block)
      flush(state, &block)
      state[:file] = FileStats.new(path: header_path(line.byteslice(DIFF.bytesize..)), additions: 0, deletions: 0,
                                   hunks: [], more: false)
      state[:body] = false
    end

    def flush(state)
      yield state[:sha], state[:file] if state[:file]
      state[:file] = nil
    end

    def record(state, line)
      file = state[:file]
      return unless file

      if (match = HUNK.match(line))
        state[:body] = true
        add_hunk(file, match)
      elsif !state[:body]
        header(file, line)
      elsif line.start_with?('+')
        file.additions += 1
      elsif line.start_with?('-')
        file.deletions += 1
      end
    end

    # The lines between `diff --git` and the first hunk: exact paths, binary.
    def header(file, line)
      if line.start_with?('+++ b/'.b, '+++ "b/'.b)
        file.path = strip_prefix(self.class.unquote(line.byteslice(4..)), 'b/')
      elsif line.start_with?('--- a/'.b, '--- "a/'.b) && file.path.nil?
        file.path = strip_prefix(self.class.unquote(line.byteslice(4..)), 'a/')
      elsif line.start_with?('Binary files '.b)
        file.additions = nil
        file.deletions = nil
      end
    end

    def add_hunk(file, match)
      if file.hunks.size >= @hunks_per_file
        file.more = true
        return
      end

      file.hunks << { 'old' => [match[1].to_i, (match[2] || '1').to_i],
                      'new' => [match[3].to_i, (match[4] || '1').to_i] }
    end

    # `a/X b/X` with renames off: both halves name one path.
    def header_path(rest)
      if rest.start_with?('"')
        closing = closing_quote(rest)
        return strip_prefix(self.class.unquote(rest.byteslice(0..closing)), 'a/') if closing
      end
      half = (rest.bytesize - 1) / 2
      strip_prefix(rest.byteslice(0, half), 'a/')
    end

    def closing_quote(text)
      index = 1
      while index < text.bytesize
        return index if text.byteslice(index) == '"'

        index += text.byteslice(index) == '\\' ? 2 : 1
      end
      nil
    end

    def strip_prefix(path, prefix)
      path.b.delete_prefix(prefix.b)
    end
  end
end
