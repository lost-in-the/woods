# frozen_string_literal: true

require 'digest'
require 'json'
require 'set'

module Woods
  module MCP
    # Pages of a full `lookup` answer.
    #
    # A large model with its concerns inlined renders to hundreds of
    # thousands of characters: one call could spend most of an agent's
    # context on a single unit. A full lookup is therefore answered in pages
    # of at most a character limit. Nothing is dropped: the pages, in order,
    # are the complete rendering, cut at line ends, and each page says how to
    # get the next.
    #
    # The limit bounds the whole text of a page as the client receives it,
    # in characters: its position lines, or in JSON its `lookup_page` object,
    # indentation and escapes, included. A limit below {MIN_MAX_CHARS} is
    # refused, and so is one at which a value that cannot be cut (one item of
    # a list in the JSON format) does not fit ({PageTooSmall} names the size
    # that does).
    #
    # Each call renders the unit afresh, and the index can be republished
    # between two calls. A page therefore carries an `answer_id`: a digest of
    # the whole rendering and the page size. A later page must name it, and
    # is refused when the rendering it would be cut from is no longer that
    # one; pages of two versions joined together are the answer of neither.
    #
    # In the JSON format the unit itself is paged, not its text: see
    # {.json_pages}.
    #
    # The limit is {DEFAULT_MAX_CHARS} unless the `WOODS_MCP_LOOKUP_MAX_CHARS`
    # environment variable sets another (0 turns paging off) or the call
    # passes `max_chars`.
    module LookupPages
      DEFAULT_MAX_CHARS = 40_000
      # The smallest page a lookup is cut into: room for the position lines
      # or `lookup_page` object and some of the unit beside them.
      MIN_MAX_CHARS = 1_000
      # Names how pages are cut. Part of every `answer_id`, so a page asked
      # for under an id an earlier cut gave is refused, not cut differently.
      PAGING_SCHEME = 2
      ENV_NAME = 'WOODS_MCP_LOOKUP_MAX_CHARS'

      # One page of a rendering.
      Page = Struct.new(:text, :number, :pages, :first_char, :last_char, :total_chars, :answer_id,
                        keyword_init: true) do
        # @return [Integer, nil] the page after this one
        def next_number
          number < pages ? number + 1 : nil
        end

        # @return [Hash] machine-readable position, for response metadata
        def to_h
          { page: number, pages: pages, first_char: first_char, last_char: last_char, total_chars: total_chars,
            next_page: next_number, answer_id: answer_id }
        end
      end

      module_function

      # @param requested [Integer, nil] the call's `max_chars`
      # @param env [Hash] environment to read {ENV_NAME} from
      # @return [Integer, nil] characters per page; nil when paging is off
      def limit(requested = nil, env: ENV)
        return requested if requested.is_a?(Integer) && requested.positive?

        configured = env[ENV_NAME].to_s.strip
        return DEFAULT_MAX_CHARS unless configured.match?(/\A\d+\z/)

        configured.to_i.zero? ? nil : configured.to_i
      end

      # Names one rendering cut at one page size (by {PAGING_SCHEME}). Sixteen hex characters of
      # its SHA-256: enough to tell two renderings of a unit apart, short
      # enough to copy into the next call.
      #
      # @param text [String] the complete rendering
      # @param max_chars [Integer]
      # @return [String]
      def answer_id(text, max_chars)
        Digest::SHA256.hexdigest("#{PAGING_SCHEME}\n#{max_chars}\n#{text}")[0, 16]
      end

      # Cut +text+ into pieces of at most +max_chars+, at line ends where a
      # line fits. Joined in order, the pieces are +text+ exactly.
      #
      # @param text [String]
      # @param max_chars [Integer]
      # @return [Array<String>] at least one piece
      def split(text, max_chars)
        pieces = [+'']
        text.each_line do |line|
          # A single line longer than a page is cut where the page ends.
          (0...line.length).step(max_chars) do |start|
            part = line[start, max_chars]
            pieces << +'' if pieces.last.length + part.length > max_chars && !pieces.last.empty?
            pieces.last << part
          end
        end
        pieces
      end

      # The text of a page of a Markdown, plain or Claude rendering: +text+
      # cut so that each piece, with its position lines from {.render}
      # around it, is at most +max_chars+.
      #
      # @param text [String] the complete rendering
      # @param max_chars [Integer]
      # @return [Array<String>] at least one piece
      # @raise [PageTooSmall] when the position lines alone fill the page
      def text_pieces(text, max_chars)
        room = max_chars - text_frame_chars(text.length)
        raise PageTooSmall, smallest_max_chars(text) unless room.positive?

        split(text, room)
      end

      # @param text [String] the complete rendering
      # @param max_chars [Integer] characters of the whole page as sent,
      #   position lines included
      # @param number [Integer] 1-based page number
      # @return [Page, nil] nil when there is no such page
      def page(text, max_chars:, number:)
        pieces = text_pieces(text, max_chars)
        return nil unless number.between?(1, pieces.size)

        before = pieces.first(number - 1).sum(&:length)
        piece = pieces[number - 1]
        Page.new(text: piece, number: number, pages: pieces.size, first_char: before + 1,
                 last_char: before + piece.length, total_chars: text.length,
                 answer_id: answer_id(text, max_chars))
      end

      # The unit cut into pages for the JSON format. A slice of a JSON
      # document does not parse, and one carried as an escaped string is
      # unreadable, so the unit itself is paged: every page holds a real part
      # of it. A value that fits travels whole; a long string is cut at line
      # ends (inside a line when one line is too long) and a long list
      # between items, and `parts` says which lines or items a page holds.
      # Merging the pages' units in order (objects by key; strings and lists
      # under the same key joined) gives the unit.
      #
      # Each page, as {.render_json} prints it, is at most +max_chars+
      # characters: every part is measured as it is printed there, at its
      # depth and with its escapes, beside the page's own `lookup_page`
      # object at its longest.
      #
      # @param unit [Hash] the unit as the JSON renderer would print it
      # @param max_chars [Integer] characters of the whole page as sent
      # @param total_chars [Integer, nil] length of the unit's whole JSON
      #   rendering (computed when not given)
      # @return [Array<Hash>] `{ 'unit' => Hash, 'parts' => Array<Hash> }`, at least one
      # @raise [PageTooSmall] when a value that cannot be cut (one list item,
      #   a number, a key) does not fit on a page of +max_chars+
      def json_pages(unit, max_chars, total_chars: nil)
        total_chars ||= JSON.pretty_generate(unit).length
        pages, bound = cut_json(unit, max_chars, total_chars)
        raise PageTooSmall, smallest_json_chars(unit, total_chars) if bound

        pages
      end

      # The smallest page size, at least {MIN_MAX_CHARS}, at which +text+
      # (or, in the JSON format, +unit+) can be cut into pages: the size
      # serves the answer and the one below it does not, so a refused caller
      # retries once.
      #
      # @param text [String] the complete rendering
      # @param unit [Hash, nil] the unit, when the format is JSON
      # @return [Integer]
      def smallest_max_chars(text, unit: nil)
        return smallest_json_chars(unit, text.length) if unit

        [text_frame_chars(text.length) + 1, MIN_MAX_CHARS].max
      end

      # The words of every refusal of a page too small.
      #
      # @param required [Integer] the smallest page size that serves the answer
      # @return [String]
      def refusal(required)
        "pages of at least #{required} characters hold it. Pass max_chars: #{required} or more, or ask for " \
          'less with sections or include_source: false.'
      end

      # Raised when no page of the requested size can hold the answer.
      class PageTooSmall < StandardError
        # @return [Integer] the smallest page size that holds it ({LookupPages.smallest_max_chars})
        attr_reader :required

        # @param required [Integer]
        def initialize(required)
          @required = required
          super("This lookup answer cannot be cut into pages that small; #{LookupPages.refusal(required)}")
        end
      end

      # {.json_pages} at one size, without refusing.
      #
      # @return [Array(Array<Hash>, Integer)] the pages, and nil or, when a
      #   value that cannot be cut does not fit, a larger size at which it does
      def cut_json(unit, max_chars, total_chars)
        frame = placeholder(total_chars)
        capacity = max_chars - render_json(frame, { 'unit' => {}, 'parts' => [] }).length - JSON_OPENING_CHARS
        sizer = JsonSizer.new(frame.pages)
        parts = unit.flat_map { |key, value| json_parts(sizer, [key.to_s], value, capacity) }
        pages, overflow = pack(parts, sizer, capacity)
        return [nil, max_chars + overflow] if overflow.positive?

        # The sizes above are upper bounds; a page over the limit is a bug
        # here, and is never sent.
        pages.each do |page|
          length = render_json(frame, page).length
          raise "lookup JSON page of #{length} characters exceeds #{max_chars}" if length > max_chars
        end
        [pages, nil]
      end

      # The bound {.cut_json} gives measures the part that did not fit at its
      # longest, so it can exceed the smallest size: a binary search between
      # the last refused size and it finds the smallest.
      def smallest_json_chars(unit, total_chars)
        low = MIN_MAX_CHARS - 1
        high = MIN_MAX_CHARS
        while (bound = cut_json(unit, high, total_chars).last)
          raise "lookup page bound #{bound} does not exceed the refused size #{high}" unless bound > high

          low = high
          high = bound
        end
        while high - low > 1
          middle = (low + high) / 2
          cut_json(unit, middle, total_chars).last ? low = middle : high = middle
        end
        high
      end

      # Characters a JSON page's `unit` and `parts` take beyond their empty
      # forms once they hold something: `{}` and `[]` open onto lines.
      JSON_OPENING_CHARS = 16

      # Measures, as an upper bound, the characters a part adds to a page
      # printed by {.render_json}: the unit sits at depth 2 of that document,
      # so a value under a path of +n+ keys is printed at indent 2(n + 1).
      class JsonSizer
        # @param largest [Integer] the largest number a span can name
        def initialize(largest)
          @largest = largest
        end

        # @return [Integer] characters of +value+ printed at +indent+
        def value_chars(value, indent)
          text = JSON.pretty_generate(value)
          text.length + (text.count("\n") * indent)
        end

        # @param path [Array<String>]
        # @param chars [Integer] the value's printed characters
        # @param span [Boolean] whether the part is listed under `parts`
        # @param opened [Set<Array<String>>] objects the page already holds
        # @return [Integer]
        def part_chars(path, chars, span, opened)
          entry = indent(path.size) + key_chars(path.last) + 2 + chars + 2
          wrappers = (1...path.size).sum do |depth|
            prefix = path.first(depth)
            opened.include?(prefix) ? 0 : (2 * indent(depth)) + key_chars(prefix.last) + 7
          end
          entry + wrappers + (span ? span_chars(path) : 0)
        end

        # @return [Integer] characters of one `parts` entry for +path+
        def span_chars(path)
          value_chars({ 'key' => path.join('.'), 'lines' => [@largest, @largest] }, 6) + 6 + 2
        end

        # @return [Integer] indent of a key under a path of +depth+ keys
        def indent(depth)
          2 * (depth + 1)
        end

        # @return [Integer] characters of +text+ inside a JSON string
        def string_chars(text)
          JSON.generate(text).length - 2
        end

        # @return [Integer] characters of one character inside a JSON string
        def char_chars(char)
          case char
          when '"', '\\', "\b", "\f", "\n", "\r", "\t" then 2
          else char.ord < 0x20 ? 6 : 1
          end
        end

        private

        def key_chars(key)
          JSON.generate(key.to_s).length
        end
      end

      # A page position whose every number is at least as long as any real
      # one: no count of an answer exceeds its character total.
      def placeholder(total_chars)
        largest = (10**[total_chars.to_s.length, 4].max) - 1
        Page.new(text: '', number: largest - 1, pages: largest, first_char: largest, last_char: largest,
                 total_chars: total_chars, answer_id: '0' * 16)
      end

      # Characters {.render} adds around a page's text, at most.
      def text_frame_chars(total_chars)
        render(placeholder(total_chars)).length
      end

      def pack(parts, sizer, capacity)
        pages = [{ 'unit' => {}, 'parts' => [], size: 0, opened: Set.new }]
        overflow = 0
        parts.each do |path, value, span, chars|
          cost = sizer.part_chars(path, chars, span, pages.last[:opened])
          if pages.last[:size].positive? && pages.last[:size] + cost > capacity
            pages << { 'unit' => {}, 'parts' => [], size: 0, opened: Set.new }
            cost = sizer.part_chars(path, chars, span, pages.last[:opened])
          end
          overflow = [overflow, cost - capacity].max
          page = pages.last
          merge_at(page['unit'], path, value)
          page['parts'] << { 'key' => path.join('.') }.merge(span) if span
          page[:size] += cost
          (1...path.size).each { |depth| page[:opened] << path.first(depth) }
        end
        [pages.map { |page| page.slice('unit', 'parts') }, overflow]
      end

      # Merge +pages+ back into the unit, by the rule a client is given. The
      # pages are not changed: the unit is built from copies of them.
      #
      # @param pages [Array<Hash>] `unit` objects, in page order
      # @return [Hash]
      def merge_json_units(pages)
        pages.each_with_object({}) { |unit, whole| merge_into(whole, deep_copy(unit)) }
      end

      # @return [Object] +value+ with every Hash, Array and String copied
      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, nested| [key, deep_copy(nested)] }
        when Array then value.map { |item| deep_copy(item) }
        when String then value.dup
        else value
        end
      end

      # One page of {.json_pages} as the JSON text of an answer.
      #
      # @param page [Page] position of the page
      # @param part [Hash] the page's entry from {.json_pages}
      # @return [String] pretty-printed JSON
      def render_json(page, part)
        continue = if page.next_number
                     "Call lookup again with the same arguments, page: #{page.next_number} and " \
                       "answer_id: \"#{page.answer_id}\"."
                   else
                     'This is the last page.'
                   end
        position = page.to_h.except(:first_char, :last_char).merge(
          parts: part.fetch('parts'),
          how_to_continue: "#{continue} Merge the unit objects of all pages in order: objects merge by key, " \
                           'and strings and lists under the same key are joined.'
        )
        JSON.pretty_generate(lookup_page: position, unit: part.fetch('unit'))
      end

      # @return [Array<Array>] `[path, value, span, chars]` pieces of +value+, each within +capacity+ where it
      #   can be cut; `chars` is the value's printed length
      def json_parts(sizer, path, value, capacity)
        chars = sizer.value_chars(value, sizer.indent(path.size))
        return [[path, value, nil, chars]] if sizer.part_chars(path, chars, false, Set.new) <= capacity

        case value
        when Hash
          return [[path, value, nil, chars]] if value.empty?

          value.flat_map { |key, nested| json_parts(sizer, path + [key.to_s], nested, capacity) }
        when String then string_parts(sizer, path, value, capacity)
        when Array then value.empty? ? [[path, value, nil, chars]] : list_parts(sizer, path, value, capacity)
        else [[path, value, nil, chars]]
        end
      end

      # A long string cut by its escaped length, at line ends where a line
      # fits and inside a line where one does not.
      def string_parts(sizer, path, value, capacity)
        room = capacity - sizer.part_chars(path, 2, true, Set.new)
        line = 1
        encoded_pieces(sizer, value, room).map do |piece, chars|
          first = line
          line += piece.count("\n")
          [path, piece, { 'lines' => [first, piece.end_with?("\n") ? line - 1 : line] }, chars + 2]
        end
      end

      # @return [Array<Array(String, Integer)>] pieces of +text+ and their
      #   escaped lengths, each at most +room+ (at least one character each)
      def encoded_pieces(sizer, text, room)
        pieces = [[+'', 0]]
        add = lambda do |part, chars|
          pieces << [+'', 0] if pieces.last[1] + chars > room && !pieces.last[0].empty?
          pieces.last[0] << part
          pieces.last[1] += chars
        end
        text.each_line do |line|
          chars = sizer.string_chars(line)
          if chars <= room
            add.call(line, chars)
          else
            line.each_char { |char| add.call(char, sizer.char_chars(char)) }
          end
        end
        pieces
      end

      # A long list cut between items. An item is never cut: one that does
      # not fit on a page is left whole, and {.json_pages} refuses the page
      # size.
      def list_parts(sizer, path, value, capacity)
        item_indent = sizer.indent(path.size + 1)
        room = capacity - sizer.part_chars(path, 3 + sizer.indent(path.size), true, Set.new)
        slices = [[[], 0]]
        value.each do |item|
          chars = sizer.value_chars(item, item_indent) + item_indent + 2
          slices << [[], 0] if slices.last[1].positive? && slices.last[1] + chars > room
          slices.last[0] << item
          slices.last[1] += chars
        end
        first = 0
        slices.map do |slice, chars|
          span = { 'items' => [first, first + slice.size - 1] }
          first += slice.size
          [path, slice, span, 3 + sizer.indent(path.size) + chars]
        end
      end

      def merge_at(unit, path, value)
        *parents, key = path
        target = parents.reduce(unit) { |hash, name| hash[name] ||= {} }
        target[key] = target.key?(key) ? join(target[key], value) : value
      end

      def merge_into(whole, unit)
        unit.each do |key, value|
          whole[key] = whole.key?(key) ? join(whole[key], value) : value
        end
        whole
      end

      def join(existing, value)
        return merge_into(existing, value) if existing.is_a?(Hash) && value.is_a?(Hash)

        existing + value
      end

      # The page with a line above and below it saying where it sits and how
      # to continue.
      #
      # @param page [Page]
      # @return [String]
      def render(page)
        position = "lookup page #{page.number} of #{page.pages}: characters #{page.first_char}-#{page.last_char} " \
                   "of #{page.total_chars}"
        continue = if page.next_number
                     "Call lookup again with the same arguments, page: #{page.next_number} and " \
                       "answer_id: \"#{page.answer_id}\" for the next part."
                   else
                     'This is the last page.'
                   end
        # A page cut inside a line (one longer than the limit) gets a line
        # break before the closing line; `first_char`/`last_char` say exactly
        # which characters of the whole answer the page holds.
        separator = page.text.end_with?("\n") ? '' : "\n"
        "[#{position}]\n#{page.text}#{separator}[#{position}. #{continue} For a smaller answer use sections, " \
          'include_source: false, or evidence: "compact" with a query.]'
      end
    end
  end
end
