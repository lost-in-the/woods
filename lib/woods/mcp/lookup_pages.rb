# frozen_string_literal: true

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
    # The limit is {DEFAULT_MAX_CHARS} unless the `WOODS_MCP_LOOKUP_MAX_CHARS`
    # environment variable sets another (0 turns paging off) or the call
    # passes `max_chars`.
    module LookupPages
      DEFAULT_MAX_CHARS = 40_000
      ENV_NAME = 'WOODS_MCP_LOOKUP_MAX_CHARS'

      # One page of a rendering.
      Page = Struct.new(:text, :number, :pages, :first_char, :last_char, :total_chars, keyword_init: true) do
        # @return [Integer, nil] the page after this one
        def next_number
          number < pages ? number + 1 : nil
        end

        # @return [Hash] machine-readable position, for response metadata
        def to_h
          { page: number, pages: pages, first_char: first_char, last_char: last_char, total_chars: total_chars,
            next_page: next_number }
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
                 last_char: before + piece.length, total_chars: text.length)
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
                     "Call lookup again with the same arguments and page: #{page.next_number} for the next part."
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
