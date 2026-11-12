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
    # In the JSON format a page is itself a JSON object: a slice of a JSON
    # document does not parse, so the slice travels as the string `chunk`
    # beside its position, and the chunks joined in order parse as the unit.
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

      # The page as a JSON object, for the JSON format: every page parses on
      # its own. `chunk` is this page's slice of the unit's JSON document;
      # the chunks of all pages, joined in order, are that document.
      #
      # @param page [Page]
      # @return [String] pretty-printed JSON
      def render_json(page)
        continue = if page.next_number
                     "Call lookup again with the same arguments, page: #{page.next_number} and " \
                       "answer_id: \"#{page.answer_id}\". Join the chunk strings of every page in order, then " \
                       'parse the result as JSON.'
                   else
                     'This is the last page. Join the chunk strings of every page in order, then parse the ' \
                       'result as JSON.'
                   end
        JSON.pretty_generate(lookup_page: page.to_h.merge(how_to_continue: continue), chunk: page.text)
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
