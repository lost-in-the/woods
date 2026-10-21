# frozen_string_literal: true

require 'json'
require 'woods/extractors/comment_blanking'

Thread.new do
  depth = 20_000
  source = "#{'[' * depth}<<~TEXT#{']' * depth}\n  Widget\nTEXT\n"
  blanked = Woods::Extractors::CommentBlanking.ruby(source)

  puts JSON.generate(last_lines: blanked.lines.last(2).map(&:strip),
                     blanked_bytesize: blanked.bytesize, source_bytesize: source.bytesize,
                     valid_encoding: blanked.valid_encoding?)
end.value
