# frozen_string_literal: true

require 'set'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    # Content-shape credential scanner for Console MCP responses.
    #
    # Walks a serialized response tree (strings, nested Hash, nested Array)
    # and replaces substrings that match known credential formats with
    # `[REDACTED]`. Pattern matching is high-specificity (word-boundary
    # anchored, minimum-length bounded) so false positives against UUIDs,
    # email addresses, and short identifiers stay rare.
    #
    # This is Layer 2 of the defense-in-depth stack — it runs AFTER the
    # operator-configured column and EAV redaction layers so it catches
    # credentials those layers missed (newly-added EAV keys, secrets stored
    # in JSONB columns, associated records pulled via nested serialization).
    #
    # @example
    #   scanner = CredentialScanner.new
    #   value, counts = scanner.scan('token is sk_test_4eC39HqLyjWDarjtT1zdp7dc')
    #   value  # => "token is [REDACTED]"
    #   counts # => { stripe_secret_key: 1 }
    #
    class CredentialScanner
      REDACTED = '[REDACTED]'

      # High-specificity credential patterns. Each is word-boundary anchored
      # and bounded by a realistic minimum length so random short strings
      # cannot trigger a match.
      PATTERNS = {
        stripe_secret_key: /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{24,}\b/,
        stripe_publishable_key: /\bpk_(?:live|test)_[A-Za-z0-9]{24,}\b/,
        stripe_webhook_secret: /\bwhsec_[A-Za-z0-9]{24,}\b/,
        aws_access_key_id: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
        github_token: /\bgh[pousr]_[A-Za-z0-9]{36,}\b/,
        google_oauth_token: /\bya29\.[A-Za-z0-9_-]{20,}\b/,
        jwt_token: /\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/,
        pem_private_key_block: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
        slack_token: /\bxox[abpr]-[A-Za-z0-9-]{10,}\b/
      }.freeze

      # @return [Array<Symbol>] every pattern name the scanner knows about.
      def self.patterns
        PATTERNS.keys
      end

      # @param disabled_patterns [Array<Symbol, String>] names to skip at scan
      #   time. Strings are coerced to Symbols.
      def initialize(disabled_patterns: [])
        disabled = Array(disabled_patterns).to_set(&:to_sym)
        @active_patterns = PATTERNS.except(*disabled)
      end

      # Scan a value (String, Hash, Array, or any other object) for credentials.
      #
      # Strings are gsub'd against every active pattern. Hash values and Array
      # elements are walked recursively; keys and non-string scalars
      # (Integer, Float, true/false, nil) pass through untouched.
      #
      # @param value [Object]
      # @return [Array(Object, Hash{Symbol=>Integer})] two-tuple of the scanned
      #   value and a per-pattern match count. Count entries are only present
      #   for patterns that fired — callers should treat a missing key as zero.
      def scan(value)
        counts = {}
        scanned = walk(value, counts)
        [scanned, counts]
      end

      private

      def walk(value, counts)
        case value
        when String then scan_string(value, counts)
        when Hash   then value.transform_values { |val| walk(val, counts) }
        when Array  then value.map { |item| walk(item, counts) }
        else value
        end
      end

      def scan_string(str, counts)
        @active_patterns.inject(str) do |result, (name, pattern)|
          result.gsub(pattern) do
            counts[name] = (counts[name] || 0) + 1
            REDACTED
          end
        end
      end
    end
  end
end
