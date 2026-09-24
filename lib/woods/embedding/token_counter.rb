# frozen_string_literal: true

require 'set'

module Woods
  module Embedding
    # Counts with an explicitly supplied local tokenizer, otherwise estimates.
    # The caller owns the tokenizer/model match. No model is downloaded here.
    class TokenCounter
      # Legacy constants/keyword remain accepted; tokenizer_id no longer loads
      # a remote tokenizer or implies that BERT matches the configured model.
      BERT_MODEL = 'bert-base-uncased'
      CONSERVATIVE_CHARS_PER_TOKEN = 1.2

      attr_reader :chars_per_token

      def initialize(chars_per_token: CONSERVATIVE_CHARS_PER_TOKEN, tokenizer_id: nil, tokenizer: nil)
        raise ArgumentError, 'chars_per_token must be positive' unless chars_per_token.positive?

        @chars_per_token = chars_per_token
        @tokenizer = tokenizer
        @tokenizer_id = tokenizer_id
      end

      def count(text)
        return 0 if text.nil? || text.empty?
        return @tokenizer.encode(text).ids.length if @tokenizer

        warn_once('Embedding token counts are estimates: no model-matched local tokenizer was supplied. ' \
                  'Ollama uses truncate:false and rejects inputs beyond its actual context window.')
        (text.length / @chars_per_token).ceil
      end

      def exact?
        !@tokenizer.nil?
      end

      @warned_messages = Set.new
      @warned_mutex = Mutex.new

      class << self
        attr_reader :warned_messages, :warned_mutex

        # Test seam for process-wide diagnostic deduplication.
        def reset_warned!
          @warned_mutex.synchronize { @warned_messages.clear }
        end
      end

      private

      def warn_once(message)
        full = "[woods] #{message}"
        self.class.warned_mutex.synchronize do
          return if self.class.warned_messages.include?(full)

          self.class.warned_messages << full
        end
        Kernel.warn(full)
      end
    end
  end
end
