# frozen_string_literal: true

require 'json'

module Woods
  module Evaluation
    # Parses the `claude -p --output-format json` shaped payload an ablation
    # agent prints on stdout (#280).
    module AblationAgentPayload
      TOKEN_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze

      module_function

      # The last line that parses as a JSON object wins, so a preamble on
      # stdout does not hide the result.
      #
      # @param stdout [String]
      # @return [Hash, nil]
      def parse(stdout)
        stdout.to_s.lines.reverse_each do |line|
          parsed = JSON.parse(line)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          next
        end
        nil
      end

      # @param usage [Hash, nil]
      # @return [Integer, nil]
      def token_total(usage)
        return nil unless usage.is_a?(Hash)

        TOKEN_KEYS.sum { |key| usage[key].to_i }
      end
    end
  end
end
