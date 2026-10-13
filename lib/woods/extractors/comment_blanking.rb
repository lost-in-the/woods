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
    # The Ruby inside it, `#{...}` interpolation, is kept.
    #
    # Comment forms, chosen by file extension:
    # - `.rb`, `.jbuilder`: Ruby `#` comments, `=begin`/`=end`, and heredoc
    #   text, via Prism
    # - `.erb`: `<%# ... %>` tags, and a Ruby comment opening a code tag
    #   (`<% # ... %>`) up to the tag end or line end
    # - `.haml`: `-#` silent comments with their indented block, and
    #   `- # ...` Ruby comment lines
    #
    # Each form is found in one forward pass, so blanking is linear.
    module CommentBlanking
      module_function

      # A Ruby comment opening an ERB tag: `<%#` (to the tag end) or
      # `<%` then blanks then `#` (to the tag end or line end).
      ERB_COMMENT = /<%-?([ \t]*)#/

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
      # heredoc body. A `#` in a quoted string or an interpolation is not a
      # comment and is kept, as is the interpolation inside a heredoc.
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

      # The byte range of each literal text segment of a heredoc body. The
      # walk keeps its own stack, so deeply nested source cannot overflow
      # the Ruby stack. The text segments of an interpolated heredoc are
      # string parts with no opening of their own, so none is counted twice.
      #
      # @param root [Prism::Node]
      # @return [Array<Range>] Byte ranges, unsorted
      def heredoc_text(root)
        ranges = []
        stack = [root]
        until stack.empty?
          node = stack.pop
          case node
          when Prism::StringNode, Prism::XStringNode
            ranges << byte_range(node.content_loc) if heredoc?(node)
          when Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode
            if heredoc?(node)
              node.parts.each { |part| ranges << byte_range(part.content_loc) if part.is_a?(Prism::StringNode) }
            end
          end
          stack.concat(node.compact_child_nodes)
        end
        ranges.reject { |range| range.begin == range.end }
      end

      def heredoc?(node)
        node.opening_loc&.slice&.start_with?('<<')
      end

      def byte_range(location)
        location.start_offset...location.end_offset
      end

      # @return [Array<Range>] Byte ranges
      def erb_comments(source)
        scanner = StringScanner.new(source)
        ranges = []
        while scanner.skip_until(ERB_COMMENT)
          start = scanner.pos - scanner.matched_size
          tag_comment = scanner[1].empty? && !scanner.matched.start_with?('<%-')
          finish = source.bytesize
          finish = scanner.pos - scanner.matched_size if scanner.skip_until(tag_comment ? /%>/ : /%>|\n/)
          ranges << (start...finish)
          scanner.pos = finish
        end
        ranges
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
      private_class_method :ruby_prose, :heredoc_text, :heredoc?, :byte_range, :erb_comments, :haml_comments, :splice
    end
  end
end
