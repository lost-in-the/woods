# frozen_string_literal: true

require 'digest'
require 'json'

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

      # Names one rendering cut at one page size. Sixteen hex characters of
      # its SHA-256: enough to tell two renderings of a unit apart, short
      # enough to copy into the next call.
      #
      # @param text [String] the complete rendering
      # @param max_chars [Integer]
      # @return [String]
      def answer_id(text, max_chars)
        Digest::SHA256.hexdigest("#{max_chars}\n#{text}")[0, 16]
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

      # @param text [String] the complete rendering
      # @param max_chars [Integer]
      # @param number [Integer] 1-based page number
      # @return [Page, nil] nil when there is no such page
      def page(text, max_chars:, number:)
        pieces = split(text, max_chars)
        return nil unless number.between?(1, pieces.size)

        before = pieces.first(number - 1).sum(&:length)
        piece = pieces[number - 1]
        Page.new(text: piece, number: number, pages: pieces.size, first_char: before + 1,
                 last_char: before + piece.length, total_chars: text.length,
                 answer_id: answer_id(text, max_chars))
      end

      # Room the page's own `lookup_page` object takes beside the unit.
      JSON_ENVELOPE_CHARS = 900

      # The unit cut into pages for the JSON format. A slice of a JSON
      # document does not parse, and one carried as an escaped string is
      # unreadable, so the unit itself is paged: every page holds a real part
      # of it. A value that fits travels whole; a long string is cut at line
      # ends and a long list between items, and `parts` says which lines or
      # items a page holds. Merging the pages' units in order (objects by
      # key; strings and lists under the same key joined) gives the unit.
      #
      # @param unit [Hash] the unit as the JSON renderer would print it
      # @param max_chars [Integer]
      # @return [Array<Hash>] `{ 'unit' => Hash, 'parts' => Array<Hash> }`, at least one
      def json_pages(unit, max_chars)
        budget = [max_chars - JSON_ENVELOPE_CHARS, 200].max
        pages = [{ 'unit' => {}, 'parts' => [], size: 0 }]
        unit.flat_map { |key, value| json_parts([key.to_s], value, budget) }.each do |path, value, span|
          size = JSON.pretty_generate(value).length
          if pages.last[:size].positive? && pages.last[:size] + size > budget
            pages << { 'unit' => {}, 'parts' => [], size: 0 }
          end
          page = pages.last
          merge_at(page['unit'], path, value)
          page['parts'] << { 'key' => path.join('.') }.merge(span) if span
          page[:size] += size
        end
        pages.map { |page| page.slice('unit', 'parts') }
      end

      # Merge +pages+ back into the unit, by the rule a client is given.
      #
      # @param pages [Array<Hash>] `unit` objects, in page order
      # @return [Hash]
      def merge_json_units(pages)
        pages.each_with_object({}) { |unit, whole| merge_into(whole, unit) }
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

      # @return [Array<Array>] `[path, value, span]` pieces of +value+, each within +budget+ where it can be cut
      def json_parts(path, value, budget)
        return [[path, value, nil]] if JSON.pretty_generate(value).length <= budget

        case value
        when Hash then value.flat_map { |key, nested| json_parts(path + [key.to_s], nested, budget) }
        when String then string_parts(path, value, budget)
        when Array then list_parts(path, value, budget)
        else [[path, value, nil]]
        end
      end

      def string_parts(path, value, budget)
        line = 1
        split(value, budget).map do |piece|
          first = line
          line += piece.count("\n")
          [path, piece, { 'lines' => [first, piece.end_with?("\n") ? line - 1 : line] }]
        end
      end

      def list_parts(path, value, budget)
        slices = [[]]
        size = 0
        value.each do |item|
          item_size = JSON.pretty_generate(item).length
          if size.positive? && size + item_size > budget
            slices << []
            size = 0
          end
          slices.last << item
          size += item_size
        end
        first = 0
        slices.map do |slice|
          span = { 'items' => [first, first + slice.size - 1] }
          first += slice.size
          [path, slice, span]
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
