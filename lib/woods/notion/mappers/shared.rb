# frozen_string_literal: true

module Woods
  module Notion
    module Mappers
      # Shared helpers for Notion mapper classes.
      module Shared
        # Notion's rich_text content limit, counted in **UTF-16 code units**
        # — not Ruby characters. A character outside the BMP (an emoji, most
        # CJK extension blocks) costs two units, so a char-count check let
        # payloads up to twice the limit through and the API rejected them
        # with a 400 on every run (EXP-2).
        MAX_RICH_TEXT_LENGTH = 2000

        # Marks a truncated value; costs 3 UTF-16 units.
        TRUNCATION_SUFFIX = '...'

        # Build a Notion rich_text property, truncating to API limits.
        #
        # @param text [String]
        # @return [Hash]
        def rich_text_property(text)
          { rich_text: [{ text: { content: truncate_to_utf16_limit(text.to_s) } }] }
        end

        private

        # Truncate to {MAX_RICH_TEXT_LENGTH} UTF-16 code units, reserving room
        # for {TRUNCATION_SUFFIX}.
        #
        # Walks whole characters, so a surrogate pair is never split — a lone
        # surrogate is not valid UTF-8 and would fail the request differently.
        #
        # @param content [String]
        # @return [String] the input unchanged when it already fits
        def truncate_to_utf16_limit(content)
          # UTF-8 never spends fewer bytes than UTF-16 spends units (1/2/3
          # bytes for one unit, 4 for two), so this settles the common case
          # without walking the string.
          return content if content.bytesize <= MAX_RICH_TEXT_LENGTH
          return content if utf16_length(content) <= MAX_RICH_TEXT_LENGTH

          budget = MAX_RICH_TEXT_LENGTH - TRUNCATION_SUFFIX.length
          used = 0
          kept = +''
          content.each_char do |char|
            cost = char.ord >= 0x10000 ? 2 : 1
            break if used + cost > budget

            kept << char
            used += cost
          end
          kept << TRUNCATION_SUFFIX
        end

        # @param content [String]
        # @return [Integer] length in UTF-16 code units
        def utf16_length(content)
          content.each_char.sum { |char| char.ord >= 0x10000 ? 2 : 1 }
        end
      end
    end
  end
end
