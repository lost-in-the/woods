# frozen_string_literal: true

require 'prism'
require 'strscan'
require_relative 'view_engines/haml'

module Woods
  module Extractors
    # Blanks the comments of a Ruby or template source so a scan for calls
    # never reads commented-out code. Every comment byte except a newline
    # becomes a space, so line structure is kept and the result can be
    # scanned exactly like the original.
    #
    # Comment forms, chosen by file extension:
    # - `.rb`, `.jbuilder`: Ruby `#` comments and `=begin`/`=end`, via Prism
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
                 when '.rb', '.jbuilder' then ruby_comments(source)
                 when '.erb' then erb_comments(source)
                 when '.haml' then haml_comments(source)
                 else []
                 end
        ranges.empty? ? source : splice(source, ranges)
      end

      # @return [Array<Range>] Byte ranges
      def ruby_comments(source)
        Prism.parse_comments(source).map do |comment|
          comment.location.start_offset...comment.location.end_offset
        end
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
      private_class_method :ruby_comments, :erb_comments, :haml_comments, :splice
    end
  end
end
