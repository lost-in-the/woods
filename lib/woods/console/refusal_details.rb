# frozen_string_literal: true

module Woods
  module Console
    # Optional machine-readable detail on a Console validation refusal: a
    # stable `code`, the `argument` the caller should change, and a `hint`
    # naming the accepted form. The message text stays the human-readable
    # refusal; these fields travel beside it to the MCP client.
    module RefusalDetails
      attr_reader :code, :argument, :hint

      # @param message [String, nil]
      # @param code [String, Symbol, nil]
      # @param argument [String, nil]
      # @param hint [String, nil]
      def initialize(message = nil, code: nil, argument: nil, hint: nil)
        super(message)
        @code = code&.to_s
        @argument = argument
        @hint = hint
      end

      # @return [Hash{Symbol=>String}] Only the fields that are set
      def details
        { code: code, argument: argument, hint: hint }.compact
      end

      # Refusal text with the hint appended, so clients that show only the
      # text still see how to correct the call.
      #
      # @param text [String]
      # @param hint [String, nil]
      # @return [String]
      def self.text_with_hint(text, hint)
        hint ? "#{text}\nHint: #{hint}" : text
      end

      # Tool-result `_meta` for a refusal, keyed as the Index server keys it.
      #
      # @param details [Hash] `code`, `argument` and `hint` (any may be absent)
      # @param tool [String]
      # @return [Hash, nil] nil when there is no detail to report
      def self.meta(details, tool)
        return nil if details.empty?

        { error_code: details[:code], tool: tool, argument: details[:argument], hint: details[:hint] }.compact
      end
    end
  end
end
