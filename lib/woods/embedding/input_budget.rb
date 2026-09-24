# frozen_string_literal: true

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Embedding
    # A refusal, never a request for the retry wrapper to repeat the same input.
    class InputLimitError < Woods::Error; end

    # Counts used for admission are explicitly distinguished from sizing estimates.
    # Byte BPE starts with UTF-8 bytes and only merges them: its token count cannot
    # exceed bytesize. This bound applies to the known OpenAI embedding encodings,
    # not arbitrary tokenizers (whose normalization or special tokens may differ).
    # Encoding mapping and token-byte examples:
    # https://developers.openai.com/cookbook/examples/how_to_count_tokens_with_tiktoken
    class InputBudget
      attr_reader :limit, :method, :model

      def initialize(limit:, model: nil, method: 'estimate', chars_per_token: 1.2)
        raise ArgumentError, 'input limit must be positive' unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, 'chars_per_token must be positive' unless chars_per_token.positive?

        @limit = limit
        @model = model
        @method = method
        @chars_per_token = chars_per_token
      end

      def self.for(provider, limit:, chars_per_token:)
        supplied = provider.input_budget if provider.respond_to?(:input_budget)
        return new(limit: limit, chars_per_token: chars_per_token) unless supplied
        return supplied unless limit < supplied.limit

        supplied.with_limit(limit)
      end

      # Preserve the provider's counting policy under a stricter caller cap.
      def with_limit(value)
        self.class.new(limit: [limit, value].min, model: model, method: method, chars_per_token: @chars_per_token)
      end

      def count(text)
        utf8 = text.encode(Encoding::UTF_8)
        raise InputLimitError, 'Embedding input requires valid UTF-8 text' unless utf8.valid_encoding?

        method == 'utf8_bytes_bound' ? utf8.bytesize : (utf8.length / @chars_per_token).ceil
      rescue EncodingError
        raise InputLimitError, 'Embedding input requires valid UTF-8 text'
      end

      def fits?(text)
        count(text) <= limit
      end

      def validate!(text)
        size = count(text)
        return text if size <= limit

        raise InputLimitError, "Embedding input limit exceeded (#{method}: #{size}, limit: #{limit}); split the input"
      end

      def identity
        { 'method' => method, 'limit' => limit, 'model' => model, 'chars_per_token' => @chars_per_token }
      end
    end
  end
end
