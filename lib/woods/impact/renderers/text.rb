# frozen_string_literal: true

require 'json'

module Woods
  module Impact
    module Renderers
      # Single-line, bounded labels. Never insert source-controlled markup.
      module Text
        # @param value [Object] JSON value or text
        # @return [String] bounded raw text, with explicit clipping
        def self.short(value)
          text = value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
          text.length > 240 ? "#{text[0, 239]}…" : text
        end

        # @param value [Object]
        # @return [String] safe CommonMark text, including table and HTML contexts
        def self.markdown(value)
          short(value).gsub(/[&<>"'`|\\\[\]()*_~{}!#.:@[:cntrl:]]/) { |char| "&##{char.ord};" }
        end

        # @param value [Object]
        # @return [String] Mermaid numeric entities inside quoted labels
        def self.mermaid(value)
          short(value).gsub(/[^a-zA-Z0-9_ :.-]/) { |char| "##{char.ord};" }
        end

        # @param item [Hash] typed public identity
        # @return [String] raw identity label; callers escape for their format
        def self.identity(item)
          "#{item['identifier']} [#{item['type']}]"
        end

        # @param item [Hash] endpoint-specific evidence
        # @return [String] raw retained context label
        def self.context(item)
          "#{item['endpoint']} gen:#{item['generation']}"
        end
      end
    end
  end
end
