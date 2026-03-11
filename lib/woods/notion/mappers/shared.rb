# frozen_string_literal: true

module CodebaseIndex
  module Notion
    module Mappers
      # Shared helpers for Notion mapper classes.
      module Shared
        MAX_RICH_TEXT_LENGTH = 2000

        # Build a Notion rich_text property, truncating to API limits.
        #
        # @param text [String]
        # @return [Hash]
        def rich_text_property(text)
          content = text.to_s
          content = "#{content[0...1997]}..." if content.length > MAX_RICH_TEXT_LENGTH
          { rich_text: [{ text: { content: content } }] }
        end
      end
    end
  end
end
