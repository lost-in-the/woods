# frozen_string_literal: true

require 'prism'
require 'strscan'
require_relative 'view_engines/haml'

module Woods
  module Extractors
    # Blanks the comments of a Ruby or template source so a scan never reads
    # a comment: a reference that appears only in a comment is prose, and
    # prose never produces a dependency edge. Every dependency scan reads its
    # source through this module. Every comment byte except a newline becomes
    # a space, so line structure and byte offsets are kept and the result can
    # be scanned exactly like the original.
    #
    # Heredoc text is prose too: a heredoc body holds YAML, SQL, markdown, or
    # other text that is not Ruby, so its literal text is blanked as well.
    # The Ruby inside it, `#{...}` interpolation, is kept. A body that is
    # Ruby is kept whole: one tagged `RUBY` or `RB`, and one passed to
    # `class_eval`, `module_eval`, `instance_eval`, or `eval`.
    #
    # Comment forms, chosen by file extension:
    # - `.rb`, `.jbuilder`: Ruby `#` comments, `=begin`/`=end`, and heredoc
    #   text, via Prism
    # - `.erb`: `<%# ... %>` tags, and a Ruby comment opening a code tag
    #   (`<% # ... %>`) up to the tag end or line end, and a line inside a
    #   code tag that starts with `#`
    # - `.haml`: `-#` silent comments with their indented block, and
    #   `- # ...` Ruby comment lines
    #
    # Each form is found in one forward pass, so blanking is linear.
    module CommentBlanking
      module_function

      ERB_TAG_OPEN = /<%/
      ERB_TAG_OPEN_SIZE = 2
      ERB_TAG_CLOSE = /%>/
      ERB_TAG_CLOSE_SIZE = 2

      # A Ruby comment opening an ERB tag: `<%#` (to the tag end) or
      # `<%` then blanks then `#` (to the tag end or line end).
      ERB_COMMENT_START = /-?([ \t]*)#/

      # A `#` comment that is the first thing on a line inside a code tag,
      # to the line end.
      ERB_COMMENT_LINE = /(?<=\n)[ \t]*\K#(?!\{)[^\n]*/

      # Heredoc tags whose body is Ruby.
      RUBY_HEREDOC_TAGS = %w[RUBY RB].freeze

      # Methods that evaluate a string argument as Ruby.
      EVAL_METHODS = %i[class_eval module_eval instance_eval eval].freeze

      # A HAML Ruby line whose code is only a comment.
      HAML_RUBY_COMMENT = /\A[ \t]*-[ \t]+#/

      # @param source [String] File source
      # @param file_path [String] Path, for its extension
      # @return [String] The source with its comments blanked
      def blank(source, file_path)
        ranges = case File.extname(file_path.to_s)
                 when '.rb', '.jbuilder' then ruby_prose(source)
                 when '.erb' then erb_comments(source)
                 when '.haml' then haml_comments(source)
                 else []
                 end
        ranges.empty? ? source : splice(source, ranges)
      end

      # Blanks `#` comments, `=begin`/`=end` blocks, and the text of every
      # heredoc body that is not Ruby. A `#` in a quoted string or an
      # interpolation is not a comment and is kept, as is the interpolation
      # inside a heredoc.
      #
      # @param source [String] Ruby source, a whole file or an excerpt
      # @return [String] The source with its comments and heredoc text
      #   blanked: the same object when it holds neither
      def ruby(source)
        return source unless source.include?('#') || source.include?('=begin') || source.include?('<<')

        ranges = ruby_prose(source)
        ranges.empty? ? source : splice(source, ranges)
      end

      # @return [Array<Range>] Byte ranges, sorted
      def ruby_prose(source)
        result = Prism.parse(source)
        comments = result.comments.map { |comment| comment.location.start_offset...comment.location.end_offset }
        (comments + heredoc_text(result.value)).sort_by(&:begin)
      end

      # The byte range of each literal text segment of a non-Ruby heredoc
      # body. The walk keeps its own stack, so deeply nested source cannot
      # overflow the Ruby stack. A call is visited before its arguments, so
      # an eval call marks its heredoc arguments as Ruby before they are
      # reached. The text segments of an interpolated heredoc are string
      # parts with no opening of their own, so none is counted twice.
      #
      # @param root [Prism::Node]
      # @return [Array<Range>] Byte ranges, unsorted
      def heredoc_text(root)
        ranges = []
        evaluated = {}.compare_by_identity
        stack = [root]
        until stack.empty?
          node = stack.pop
          case node
          when Prism::CallNode
            node.arguments&.arguments&.each { |arg| evaluated[arg] = true } if EVAL_METHODS.include?(node.name)
          when Prism::StringNode, Prism::XStringNode
            ranges << byte_range(node.content_loc) if prose_heredoc?(node, evaluated)
          when Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode
            if prose_heredoc?(node, evaluated)
              node.parts.each { |part| ranges << byte_range(part.content_loc) if part.is_a?(Prism::StringNode) }
            end
          end
          stack.concat(node.compact_child_nodes)
        end
        ranges.reject { |range| range.begin == range.end }
      end

      # A heredoc whose body is not Ruby: not tagged as Ruby and not the
      # argument of an eval method.
      def prose_heredoc?(node, evaluated)
        opening = node.opening_loc&.slice
        return false unless opening&.start_with?('<<')

        !evaluated.key?(node) && !RUBY_HEREDOC_TAGS.include?(opening.delete("-<~'\"`"))
      end

      def byte_range(location)
        location.start_offset...location.end_offset
      end

      # @return [Array<Range>] Byte ranges
      def erb_comments(source)
        scanner = StringScanner.new(source)
        ranges = []
        while scanner.skip_until(ERB_TAG_OPEN)
          tag_start = scanner.pos - ERB_TAG_OPEN_SIZE
          rest = scanner.check_until(ERB_TAG_CLOSE)
          tag_end = rest ? scanner.pos + rest.bytesize - ERB_TAG_CLOSE_SIZE : source.bytesize
          if scanner.skip(ERB_COMMENT_START)
            tag_comment = scanner[1].empty? && !scanner.matched.start_with?('-')
            finish = tag_end
            unless tag_comment
              line = scanner.check_until(/\n/)
              finish = [finish, scanner.pos + line.bytesize - 1].min if line
            end
            ranges << (tag_start...finish)
            scanner.pos = finish
          end
          ranges.concat(comment_lines(source, scanner.pos, tag_end))
          scanner.pos = tag_end
        end
        ranges
      end

      # The `#` comment on each line of a code tag that starts with it, from
      # `from` up to the tag end.
      #
      # @return [Array<Range>] Byte ranges
      def comment_lines(source, from, tag_end)
        body = source.byteslice(from, tag_end - from).b
        body.to_enum(:scan, ERB_COMMENT_LINE).map do
          match = Regexp.last_match
          (from + match.begin(0))...(from + match.end(0))
        end
      end

      # A `-#` block is its line plus every following line that is blank or
      # indented deeper, the same rule {ViewEngines::Haml} uses.
      #
      # @return [Array<Range>] Byte ranges
      def haml_comments(source)
        ranges = []
        offset = 0
        block = nil
        source.each_line do |line|
          indent = line[/\A[ \t]*/].length
          unless block && (line.strip.empty? || indent > block[:indent])
            ranges << (block[:start]...offset) if block
            block = nil
            if line.match?(ViewEngines::Haml::SILENT_COMMENT)
              block = { indent: indent, start: offset }
            elsif line.match?(HAML_RUBY_COMMENT)
              ranges << (offset...(offset + line.bytesize))
            end
          end
          offset += line.bytesize
        end
        ranges << (block[:start]...offset) if block
        ranges
      end

      # Rebuilds the source with each (sorted, disjoint) byte range blanked.
      def splice(source, ranges)
        blanked = String.new(capacity: source.bytesize, encoding: source.encoding)
        position = 0
        ranges.each do |range|
          blanked << source.byteslice(position, range.begin - position)
          blanked << source.byteslice(range.begin, range.end - range.begin).b.tr("^\n", ' ').force_encoding(source.encoding)
          position = range.end
        end
        blanked << source.byteslice(position, source.bytesize - position)
      end
      private_class_method :ruby_prose, :heredoc_text, :prose_heredoc?, :byte_range, :erb_comments, :comment_lines, :haml_comments, :splice
    end
  end
end
