# frozen_string_literal: true

module CodebaseIndex
  module Operator
    # Classifies pipeline errors by severity and suggests remediation.
    #
    # @example
    #   escalator = ErrorEscalator.new
    #   result = escalator.classify(Timeout::Error.new("connection timed out"))
    #   result[:severity]     # => :transient
    #   result[:remediation]  # => "Retry after a short delay"
    #
    class ErrorEscalator
      TRANSIENT_PATTERNS = [
        { class_pattern: /Timeout|ETIMEDOUT/, category: 'timeout', remediation: 'Retry after a short delay' },
        { class_pattern: /Net::/, category: 'network', remediation: 'Check network connectivity and retry' },
        { class_pattern: /RateLimited|429/, category: 'rate_limit',
          remediation: 'Back off and retry with exponential delay' },
        { class_pattern: /CircuitOpenError/, category: 'circuit_open',
          remediation: 'Wait for circuit breaker reset timeout' },
        { class_pattern: /ConnectionPool|Busy/, category: 'resource_contention',
          remediation: 'Wait for resources to free up' }
      ].freeze

      PERMANENT_PATTERNS = [
        { class_pattern: /NameError|NoMethodError/, category: 'code_error',
          remediation: 'Fix the code error and re-extract' },
        { class_pattern: /Errno::ENOENT|FileNotFoundError/, category: 'missing_file',
          remediation: 'Verify file paths and re-run extraction' },
        { class_pattern: /JSON::ParserError/, category: 'corrupt_data',
          remediation: 'Clean index and re-extract' },
        { class_pattern: /ConfigurationError/, category: 'configuration',
          remediation: 'Review CodebaseIndex configuration' },
        { class_pattern: /ExtractionError/, category: 'extraction_failure',
          remediation: 'Check extraction logs for specific failure details' }
      ].freeze

      # Classify an error by severity and suggest remediation.
      #
      # @param error [StandardError] The error to classify
      # @return [Hash] :severity (:transient or :permanent), :category, :remediation, :error_class, :message
      def classify(error)
        error_string = "#{error.class} #{error.message}"

        match = find_match(error_string, TRANSIENT_PATTERNS, :transient) ||
                find_match(error_string, PERMANENT_PATTERNS, :permanent)

        if match
          match.merge(error_class: error.class.name, message: error.message)
        else
          {
            severity: :unknown,
            category: 'unclassified',
            remediation: 'Investigate error details and check logs',
            error_class: error.class.name,
            message: error.message
          }
        end
      end

      private

      # @param error_string [String]
      # @param patterns [Array<Hash>]
      # @param severity [Symbol]
      # @return [Hash, nil]
      def find_match(error_string, patterns, severity)
        patterns.each do |pattern|
          next unless error_string.match?(pattern[:class_pattern])

          return {
            severity: severity,
            category: pattern[:category],
            remediation: pattern[:remediation]
          }
        end
        nil
      end
    end
  end
end
