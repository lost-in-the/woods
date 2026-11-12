# frozen_string_literal: true

# The limit on lines a change adds to Markdown, YAML and shell files.
#
# Ruby is held to the same width by RuboCop (`Layout/LineLength`). The files
# checked here predate any limit and many hold lines hundreds of columns
# wide, so the check reads only the lines a branch adds: nothing is reflowed
# to pass it, and `git blame` keeps its history.
#
# Run it through `script/check-line-length`.
module LineLengthCheck
  LIMIT = 120

  # File types the check covers.
  CHECKED = /\.(?:md|ya?ml|sh)\z/

  # Generated or archived files, which nobody wraps by hand.
  SKIPPED = [
    %r{\A\.Codex/},
    %r{\Abench/evaluation/},
    %r{\Aspec/fixtures/},
    %r{\Adocs/self-analysis/},
    %r{\Aplugin/hooks/woods-input-rules\.sh\z},
    /\ACHANGELOG\.md\z/
  ].freeze

  # A URL or a Markdown link target. A line is exempt when it is short without them.
  LINK = %r{\S*(?:https?://|\]\()\S+}
  LINKLESS_LENGTH = 60

  FENCE = /\A\s*(?:```|~~~)/
  GENERATED_OPEN = /<!-- release-state:(?!end)/
  GENERATED_CLOSE = /<!-- release-state:end -->/

  Violation = Struct.new(:path, :number, :width) do
    def to_s
      "#{path}:#{number}: #{width} columns (limit #{LIMIT})"
    end
  end

  module_function

  # @param diff [String] `git diff --unified=0` output
  # @return [Array<Array(String, Integer, String)>] path, line number and text of each added line
  def added_lines(diff)
    path = nil
    number = nil
    diff.each_line(chomp: true).with_object([]) do |line, added|
      if number && line.start_with?('+')
        added << [path, number, line[1..]] if path
        number += 1
      else
        path, number = position(line, path, number)
      end
    end
  end

  # Where the next added line falls, after a line that is not one. A file's
  # header ends at its first hunk; from there a leading `+` is content.
  #
  # @return [Array(String, Integer)] path and line number; the number is nil inside a header
  def position(line, path, number)
    return [nil, nil] if line.start_with?('diff --git ')
    return [line[%r{\A\+\+\+ b/(.+)}, 1], nil] if number.nil? && line.start_with?('+++ ')
    return [path, line[/\A@@ -\S+ \+(\d+)/, 1].to_i] if line.start_with?('@@ ')

    [path, number]
  end

  # @param added [Array<Array(String, Integer, String)>] the result of {.added_lines}
  # @param reader [#call] given a path, the file's current lines
  # @return [Array<Violation>]
  def violations(added, reader: ->(path) { File.readlines(path, chomp: true, encoding: 'UTF-8') })
    files = Hash.new { |cache, path| cache[path] = reader.call(path) }
    added.filter_map do |path, number, text|
      next unless checked?(path) && text.length > LIMIT
      next if exempt?(path, text, files[path].first(number - 1))

      Violation.new(path, number, text.length)
    end
  end

  # @param path [String] repository-relative path
  # @return [Boolean]
  def checked?(path)
    path.match?(CHECKED) && SKIPPED.none? { |skipped| path.match?(skipped) }
  end

  # @param path [String]
  # @param text [String] the added line
  # @param above [Array<String>] the lines before it in the file
  # @return [Boolean] whether the line cannot or must not be wrapped
  def exempt?(path, text, above)
    return true if text.gsub(LINK, '').length <= LINKLESS_LENGTH
    return false unless path.end_with?('.md')

    table_or_heading?(text) || above.grep(FENCE).size.odd? || generated?(above)
  end

  def table_or_heading?(text)
    text.match?(/\A\s*\|/) || text.match?(/\A#+ /)
  end

  # Inside a `release-state` fence, which `release:prepare` writes.
  def generated?(above)
    above.grep(GENERATED_OPEN).size > above.grep(GENERATED_CLOSE).size
  end
end
