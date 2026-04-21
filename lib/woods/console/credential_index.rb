# frozen_string_literal: true

require 'set'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    # Boot-time index of every string leaf in `Rails.application.credentials`.
    #
    # The pattern-based {CredentialScanner} catches *known credential shapes*
    # (Stripe `sk_live_…`, AWS `AKIA…`, etc.). It cannot catch a value whose
    # shape is unknown — a hand-rolled HMAC secret, a Twilio auth token, a
    # third-party webhook signing key. This index closes that gap by
    # remembering the host app's *actual* credential values and substring-
    # matching them in every Console MCP response, so a row whose value
    # exactly matches a stored credential is redacted regardless of column
    # name or value shape.
    #
    # The index is built once at server boot — walking encrypted credentials
    # on every request would be both expensive and unsafe (it requires the
    # master key). Each string leaf with length ≥ {MIN_LENGTH} is added to a
    # frozen Set, and a pre-compiled `Regexp.union` is held for one-pass
    # `gsub` substitution.
    #
    # ### Multi-DB / sharded caveat
    # The index reflects credentials available to the *Rails process* that
    # boots the Console MCP server. A separate database that holds its own
    # secrets (e.g., a vendored CMS app sharing the same Rails host) is not
    # in scope. Use Layer 3 (`console_redacted_columns` /
    # `console_redacted_key_values`) for those.
    #
    # ### Missing master key
    # In environments without `config/master.key` (CI, fresh checkouts) the
    # `Rails.application.credentials.config` call raises
    # `ActiveSupport::EncryptedConfiguration::MissingKeyError` or
    # `ActiveSupport::MessageEncryptor::InvalidMessage`. {.build} catches
    # both *by name* (no constant reference, so the class load order is
    # irrelevant) and returns an empty index — the server still boots, the
    # other defense layers still apply.
    #
    # @example
    #   index = CredentialIndex.build(rails_app: Rails.application)
    #   index.match?("sk_live_actual_secret_value")  # => true
    #   index.redact("token: sk_live_actual_secret_value")
    #     # => "token: [REDACTED:credential]"
    #
    class CredentialIndex
      # Captured at require time so the mtime-check warning has a stable
      # reference point even if the clock skews later. Frozen immediately
      # to prevent accidental mutation.
      PROCESS_START = Time.now.freeze

      # Substrings shorter than this are not added to the index. Below ~12
      # chars the false-positive rate climbs sharply (env names like
      # `production`, hostnames, version strings, etc.).
      MIN_LENGTH = 12

      # Rendered marker for substring hits — distinct from the pattern
      # scanner's `[REDACTED]` so operators reading audit output can see
      # *which* layer caught the leak.
      REDACTED = '[REDACTED:credential]'

      # Encryption-related exception class names caught by name. Rails moves
      # these around between versions; matching by `Class#name` keeps us
      # from coupling to a specific constant path.
      MISSING_KEY_ERRORS = %w[
        ActiveSupport::EncryptedConfiguration::MissingKeyError
        ActiveSupport::EncryptedFile::MissingKeyError
        ActiveSupport::MessageEncryptor::InvalidMessage
      ].freeze

      class << self
        # Build an index from a Rails application's encrypted credentials.
        #
        # **Restart required after rotation.** The index is built once at
        # server boot and held in memory for the life of the MCP process.
        # When a host app rotates Rails credentials, the MCP process keeps
        # the pre-rotation secrets in its frozen Set until the process
        # restarts. New secrets added during rotation are NOT in the index
        # — only Layer 2 shape patterns can catch them until restart.
        #
        # To trigger a rebuild without restarting, call
        # `Woods::Console::Server.rebuild_credential_index` from a rotation
        # job or initializer hook. See docs/CONSOLE_MCP_SETUP.md for the
        # full restart guidance.
        #
        # @param rails_app [#credentials] usually `Rails.application`.
        # @return [CredentialIndex] populated index, or an empty index when
        #   the credentials store can't be opened.
        def build(rails_app:)
          new(secrets: collect_secrets(rails_app))
        rescue StandardError => e
          raise unless missing_key_error?(e)

          new(secrets: [])
        end

        # Emit a structured log warning when any of the given credentials
        # files has a modification time newer than `process_start`. This
        # catches the common "rotated credentials but forgot to restart"
        # situation at boot time.
        #
        # Only files that actually exist on disk are checked; missing paths
        # are silently skipped so CI and fresh-checkout environments (which
        # have no credentials file) produce no noise.
        #
        # @param credentials_files [Array<String>] Paths to check (e.g.
        #   `config/credentials.yml.enc`,
        #   `config/credentials/production.yml.enc`).
        # @param process_start [Time] When the current process started.
        #   Typically `Woods::Console::CredentialIndex::PROCESS_START`.
        # @param logger [#warn] A logger responding to `warn(event, **kwargs)`.
        # @return [void]
        def warn_if_credentials_rotated(credentials_files:, process_start:, logger:)
          credentials_files.each do |path|
            next unless File.exist?(path)

            mtime = File.mtime(path)
            next unless mtime > process_start

            logger.warn(
              'console.credential_index.stale',
              credentials_file: path,
              file_mtime: mtime.iso8601,
              process_start: process_start.iso8601,
              hint: 'Credentials file was modified after process start — ' \
                    'restart the MCP process or call ' \
                    'Woods::Console::Server.rebuild_credential_index to ' \
                    'pick up rotated secrets.'
            )
          end
        end

        private

        def collect_secrets(rails_app)
          config = rails_app.credentials.config
          collected = []
          walk(config, collected)
          collected
        end

        def walk(node, collected)
          case node
          when Hash  then node.each_value { |v| walk(v, collected) }
          when Array then node.each { |v| walk(v, collected) }
          when String
            collected << node if node.length >= MIN_LENGTH
          end
        end

        def missing_key_error?(error)
          MISSING_KEY_ERRORS.include?(error.class.name)
        end
      end

      # @return [Set<String>] frozen set of secret strings (length ≥ MIN_LENGTH).
      attr_reader :secrets

      # @return [Regexp, nil] precompiled `Regexp.union` of every secret, or
      #   nil when the index is empty (no allocation, no per-string overhead).
      attr_reader :pattern

      # @param secrets [Enumerable<String>] string leaves harvested from
      #   credentials. Duplicates are collapsed; strings shorter than
      #   {MIN_LENGTH} are dropped.
      def initialize(secrets:)
        filtered = Array(secrets).select { |s| s.is_a?(String) && s.length >= MIN_LENGTH }
        @secrets = filtered.to_set.freeze
        @pattern = @secrets.empty? ? nil : Regexp.union(@secrets.to_a)
      end

      # @return [Boolean] true when no secrets were collected (missing key,
      #   empty credentials file, or every leaf below MIN_LENGTH).
      def empty?
        @secrets.empty?
      end

      # @param str [String]
      # @return [Boolean] true when any indexed secret appears as a substring.
      def match?(str)
        return false if empty? || !str.is_a?(String)

        @pattern.match?(str)
      end

      # Replace every indexed-secret substring in `str` with {REDACTED}.
      #
      # @param str [String]
      # @return [String] redacted copy. Returns the input unchanged when the
      #   index is empty or no secret appears.
      def redact(str)
        return str if empty? || !str.is_a?(String) || !@pattern.match?(str)

        str.gsub(@pattern, REDACTED)
      end
    end
  end
end
