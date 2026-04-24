# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'set'

require_relative 'credential_index'

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
    class CredentialScanner # rubocop:disable Metrics/ClassLength
      REDACTED = '[REDACTED]'

      # High-specificity credential patterns. Each is word-boundary anchored
      # and bounded by a realistic minimum length so random short strings
      # cannot trigger a match.
      #
      # Order matters: more-specific patterns appear before less-specific
      # alternatives (e.g., `anthropic_api_key` before `openai_api_key`)
      # so the specific counter increments rather than the generic one.
      PATTERNS = {
        stripe_secret_key: /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{24,}\b/,
        stripe_publishable_key: /\bpk_(?:live|test)_[A-Za-z0-9]{24,}\b/,
        stripe_webhook_secret: /\bwhsec_[A-Za-z0-9]{24,}\b/,
        # Stripe Connect account IDs are PII per Stripe's ToS even though they
        # are not strictly secret — surfacing one in an MCP response leaks the
        # connected merchant's identity.
        stripe_connect_account_id: /\bacct_[A-Za-z0-9]{16,}\b/,
        # Klaviyo private API keys use a bare `pk_` prefix with no live/test
        # infix — they evade the Stripe publishable regex and grant full API
        # access to the Klaviyo tenant. Order matters: stripe_publishable_key
        # runs first so its more-specific match wins on Stripe values.
        klaviyo_private_key: /\bpk_[A-Za-z0-9]{34}\b/,
        aws_access_key_id: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
        github_fine_grained_pat: /\bgithub_pat_[A-Za-z0-9_]{82}\b/,
        github_token: /\bgh[pousr]_[A-Za-z0-9]{36,}\b/,
        google_oauth_token: /\bya29\.[A-Za-z0-9_-]{20,}\b/,
        jwt_token: /\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/,
        pem_private_key_block: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
        slack_token: /\bxox[abpr]-[A-Za-z0-9-]{10,}\b/,
        sendgrid_api_key: /\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b/,
        mailgun_api_key: /\bkey-[a-f0-9]{32}\b/,
        # Matches both the current `sk-ant-api03-…` / `sk-ant-admin01-…` shape
        # and the legacy `sk-ant-…` format that shipped without the
        # `api|admin` infix. Length floor prevents matching on a bare `sk-ant-`
        # prefix in logs or docs.
        anthropic_api_key: /\bsk-ant-(?:(?:api|admin)\d{2}-)?[A-Za-z0-9_-]{80,}\b/,
        openai_api_key: %r{\bsk-(?:proj-)?[A-Za-z0-9/_-]{40,}\b},
        # `rt`/`ua` extend the existing alternation to cover refresh tokens
        # (`shprt_`) and user-access tokens (`shpua_`) — the prefix list
        # before this PR missed both.
        shopify_access_token: /\bshp(?:at|ca|ss|pa|rt|ua)_[a-f0-9]{32}\b/,
        square_access_token: /\bsq0[a-z]{3}-[A-Za-z0-9_-]{22,}\b/,
        paypal_access_token: /\baccess_token\$(?:production|sandbox)\$[A-Za-z0-9]+\$[a-f0-9]+\b/,
        # Distinctive `00D<15-org-id>!<base64 payload>` shape — no FP risk
        # and one of the highest-leverage additions per the research brief.
        salesforce_access_token: /\b00D[A-Za-z0-9]{12}![A-Za-z0-9._]{80,250}\b/,
        launchdarkly_sdk_key: /\bsdk-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/,
        launchdarkly_mobile_key: /\bmob-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/,
        hubspot_private_app_token: Regexp.new(
          '\bpat-(?:na1|na2|eu1|eu2|ap1)-' \
          '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        ),
        brevo_api_key: /\bxkeysib-[a-f0-9]{64}-[A-Za-z0-9]{16}\b/,
        brevo_smtp_key: /\bxsmtpsib-[a-f0-9]{64}-[A-Za-z0-9]{16}\b/,
        kit_api_key: /\bkit_[A-Za-z0-9]{20,}\b/,
        twilio_account_sid: /\bAC[0-9a-fA-F]{32}\b/,
        twilio_api_key_sid: /\bSK[0-9a-fA-F]{32}\b/,
        twilio_verify_service_sid: /\bVA[0-9a-fA-F]{32}\b/,
        # Connection strings with embedded credentials: `postgres://user:pass@host/db`,
        # `mysql2://user:pass@host/db`, `mongodb://…`, `amqp://…`, `redis://…`.
        # Captures the entire URL — the password is part of it and redacting
        # just the password field while leaving `user@host` visible is not
        # worth the regex complexity when the host may itself be sensitive.
        database_url_with_password: Regexp.new(
          '\b(?:postgres|postgresql|mysql|mysql2|mongodb|mongodb\+srv|amqp|amqps|redis|rediss|' \
          'clickhouse|cockroachdb|mariadb)://[^\s:@/]+:[^\s@/]+@\S+'
        )
      }.freeze

      # @return [Array<Symbol>] every pattern name the scanner knows about.
      def self.patterns
        PATTERNS.keys
      end

      # Replace the boot-time credential index with a freshly built one.
      #
      # Called by `Woods::Console::Server.rebuild_credential_index` after a
      # host app rotates its Rails credentials. Thread-safe: the assignment
      # is atomic on MRI (GVL) and the new index is fully constructed before
      # being swapped in, so in-flight scans see either the old or the new
      # index — never a partial one.
      #
      # @param new_index [CredentialIndex, nil] The replacement index.
      # @return [void]
      def replace_index!(new_index)
        @secret_index = if new_index.respond_to?(:empty?) && new_index.empty?
                          nil
                        else
                          new_index
                        end
      end

      # Counter key emitted when {CredentialIndex} substring-matches a value
      # before any shape pattern fires. Distinct from pattern names so
      # observability can tell the two layers apart.
      INDEX_HIT = :credential_index

      # @param disabled_patterns [Array<Symbol, String>] names to skip at scan
      #   time. Strings are coerced to Symbols.
      # @param secret_index [#match?, #redact, nil] Optional {CredentialIndex}
      #   built from the host app's actual credentials. When present, every
      #   string is run through the index *before* the pattern pass — so a
      #   value whose shape no pattern recognizes (Twilio auth tokens,
      #   hand-rolled HMAC keys, etc.) is still redacted when it matches a
      #   stored credential exactly. Pass `nil` (or a `CredentialIndex#empty?`
      #   index) to skip the substring layer.
      def initialize(disabled_patterns: [], secret_index: nil)
        disabled = Array(disabled_patterns).to_set(&:to_sym)
        @active_patterns = PATTERNS.except(*disabled)
        @secret_index = secret_index unless secret_index.respond_to?(:empty?) && secret_index.empty?
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
        when Hash   then walk_hash(value, counts)
        when Array  then value.map { |item| walk(item, counts) }
        else value
        end
      end

      # Walk a Hash, scanning both keys and values for credentials.
      #
      # Keys are scanned by coercing them to String, running the scan, then
      # restoring the original key type — a Symbol key that carries a
      # credential-shaped string is emitted as a Symbol after redaction
      # (e.g. `:"[REDACTED]"`). String keys stay Strings. Non-String,
      # non-Symbol keys (Integer, etc.) pass through unchanged.
      def walk_hash(hash, counts)
        hash.each_with_object({}) do |(key, val), out|
          scanned_key = case key
                        when String then scan_string(key, counts)
                        when Symbol then scan_string(key.to_s, counts).to_sym
                        else             key
                        end
          out[scanned_key] = walk(val, counts)
        end
      end

      def scan_string(str, counts)
        result = redact_indexed_secrets(str, counts)
        result = scan_encoded_forms(result, counts)
        @active_patterns.inject(result) do |acc, (name, pattern)|
          acc.gsub(pattern) do
            counts[name] = (counts[name] || 0) + 1
            REDACTED
          end
        end
      end

      # Best-effort redaction of credentials that slip past the literal-pattern
      # pass because they are URL-encoded (`sk%5Ftest%5F…`) or base64-wrapped
      # (`c2tfdGVzdF8…`). For each candidate substring we try the decoded form
      # against every active pattern; if any pattern matches, we redact the
      # encoded substring in the original string. This is a defense-in-depth
      # layer — the literal patterns remain the primary guarantee and the
      # decoded scan runs only over substrings whose shape suggests encoding.
      def scan_encoded_forms(str, counts)
        str = scan_url_encoded(str, counts) if str.include?('%')
        scan_base64(str, counts)
      end

      URL_ENCODED_CANDIDATE = %r{[A-Za-z0-9%_.~+/=-]{24,}}
      # No trailing `\b` anchor — `\b` requires a word/non-word transition
      # and fails at end-of-string after a `=` padding char. Use a negative
      # look-ahead to stop at the next alphanumeric character instead.
      BASE64_CANDIDATE = %r{\b[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/])}
      private_constant :URL_ENCODED_CANDIDATE, :BASE64_CANDIDATE

      def scan_url_encoded(str, counts)
        str.gsub(URL_ENCODED_CANDIDATE) do |candidate|
          next candidate unless candidate.include?('%')

          decoded = safely_unescape(candidate)
          credential_name = first_matching_pattern(decoded)
          if credential_name
            counts[credential_name] = (counts[credential_name] || 0) + 1
            REDACTED
          else
            candidate
          end
        end
      end

      def scan_base64(str, counts)
        str.gsub(BASE64_CANDIDATE) do |candidate|
          decoded = safely_base64_decode(candidate)
          next candidate unless decoded

          credential_name = first_matching_pattern(decoded)
          if credential_name
            counts[credential_name] = (counts[credential_name] || 0) + 1
            REDACTED
          else
            candidate
          end
        end
      end

      def first_matching_pattern(value)
        @active_patterns.each do |name, pattern|
          return name if pattern.match?(value)
        end
        nil
      end

      def safely_unescape(value)
        CGI.unescape(value)
      rescue ArgumentError
        value
      end

      def safely_base64_decode(value)
        decoded = Base64.strict_decode64(value)
        decoded.force_encoding(Encoding::UTF_8)
        return nil unless decoded.valid_encoding?
        # CPU short-circuit: credential strings are printable ASCII. If
        # the decoded bytes are mostly non-printable (likely a binary
        # hash / random bytes / image), skip the pattern scan entirely —
        # avoids running every `active_patterns` regex over gigabytes of
        # hex dumps on every scan.
        return nil unless mostly_printable?(decoded)

        decoded
      rescue ArgumentError
        nil
      end

      PRINTABLE_RATIO_THRESHOLD = 0.85
      private_constant :PRINTABLE_RATIO_THRESHOLD

      def mostly_printable?(str)
        return false if str.empty?

        # ASCII printable (0x20-0x7e) + tab/newline; the threshold matches
        # base64 encodings of typical credential shapes (sk_live_..., AKIA...,
        # ghp_..., etc.) which are 100% printable.
        printable = str.each_char.count { |c| c.match?(/[\t\n\x20-\x7e]/) }
        printable.to_f / str.length >= PRINTABLE_RATIO_THRESHOLD
      end

      def redact_indexed_secrets(str, counts)
        return str unless @secret_index&.match?(str)

        redacted = @secret_index.redact(str)
        counts[INDEX_HIT] = (counts[INDEX_HIT] || 0) + redacted.scan(CredentialIndex::REDACTED).size
        redacted
      end
    end
  end
end
