# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'credential_scanner'

module Woods
  module Console
    # Logs all Tier 4 tool invocations to a JSONL file.
    #
    # Each line is a JSON object with: tool name, params, timestamp,
    # confirmation status, and result summary.
    #
    # Params and result summaries are passed through {CredentialScanner} so
    # credentials an agent pastes inline into `console_eval` (or any other
    # tool) do not land in audit logs unredacted.
    #
    # @example
    #   logger = AuditLogger.new(path: 'log/console_audit.jsonl')
    #   logger.log(tool: 'console_eval', params: { code: '1+1' },
    #              confirmed: true, result_summary: '2')
    #   logger.entries # => [{ "tool" => "console_eval", ... }]
    #
    class AuditLogger
      # Soft cap on any single logged field. Stops an attacker with Tier-4
      # access from filling disk via arbitrarily long params.
      MAX_FIELD_CHARS = 16_384

      # @param path [String] Path to the JSONL audit log file
      # @param scanner [#scan, nil] CredentialScanner override (mostly for tests).
      def initialize(path:, scanner: nil)
        @path = path
        @scanner = scanner || CredentialScanner.new
      end

      # Write an audit entry.
      #
      # @param tool [String] Tool name
      # @param params [Hash] Tool parameters
      # @param confirmed [Boolean] Whether confirmation was granted
      # @param result_summary [String] Brief result description
      # @return [void]
      def log(tool:, params:, confirmed:, result_summary:)
        ensure_directory!

        # Redact BEFORE truncating (CON-5). Truncation cuts at
        # MAX_FIELD_CHARS, and a credential straddling that boundary is split
        # in two: the scanner's word-boundary/length-anchored patterns no
        # longer match the surviving prefix, so cleartext `sk_live_…` reached
        # the JSONL. Scanning the whole value first means the boundary can
        # only ever fall inside `[REDACTED]`.
        entry = {
          tool: tool,
          params: truncate_deep(redact(params)),
          confirmed: confirmed,
          result_summary: truncate_value(redact(result_summary)),
          timestamp: Time.now.utc.iso8601
        }

        # Exclusive flock around the append — concurrent Tier-4 invocations
        # across Puma threads would otherwise interleave bytes and produce
        # malformed JSONL lines (integrity hit on audit review).
        File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |f|
          f.flock(File::LOCK_EX)
          f.puts(JSON.generate(sanitize_controls(entry)))
        end
      end

      private

      # Run a value through CredentialScanner. The scanner returns
      # `[redacted_value, match_counts]`; the audit log wants only the
      # redacted payload. nil scanner means pass-through (tests).
      def redact(value)
        return value unless @scanner && value

        redacted, _counts = @scanner.scan(value)
        redacted
      rescue StandardError
        # Never let redaction failure block audit writes — drop the value
        # to a safe sentinel rather than logging raw content.
        '[REDACTION_FAILED]'
      end

      # Recursively cap strings at MAX_FIELD_CHARS. Arrays/hashes preserve
      # shape; scalars other than String pass through unchanged.
      def truncate_deep(value)
        case value
        when Hash then value.transform_values { |v| truncate_deep(v) }
        when Array then value.map { |v| truncate_deep(v) }
        else truncate_value(value)
        end
      end

      def truncate_value(value)
        return value unless value.is_a?(String) && value.length > MAX_FIELD_CHARS

        "#{value[0, MAX_FIELD_CHARS]}… [truncated #{value.length - MAX_FIELD_CHARS} chars]"
      end

      # Defense-in-depth against log injection: strip ASCII control characters
      # (NUL through US + DEL, except TAB) from every string in the entry
      # before it reaches `JSON.generate`. `JSON.generate` already escapes
      # these in string values, but (a) some downstream log readers parse
      # JSONL by splitting on literal `\n` before JSON-parsing, and (b) a
      # future consumer that decodes and reprints values (e.g. a terminal
      # audit UI) would re-expose injection vectors.
      CONTROL_CHARS = /[\x00-\x08\x0A-\x1F\x7F]/
      private_constant :CONTROL_CHARS

      def sanitize_controls(value)
        case value
        when String then value.gsub(CONTROL_CHARS, '')
        when Hash   then value.transform_keys { |k| sanitize_controls(k) }
                              .transform_values { |v| sanitize_controls(v) }
        when Array  then value.map { |v| sanitize_controls(v) }
        else value
        end
      end

      public

      # Read all audit entries.
      #
      # @return [Array<Hash>] Parsed JSONL entries
      def entries
        return [] unless File.exist?(@path)

        # Explicit UTF-8: entries are written as UTF-8 (the truncation notice
        # alone carries a multibyte ellipsis), so a bare read would tag them
        # with the process default external encoding and raise under LANG=C.
        File.readlines(@path, encoding: Encoding::UTF_8).filter_map do |line|
          JSON.parse(line.strip) unless line.strip.empty?
        end
      end

      # Number of audit entries.
      #
      # @return [Integer]
      def size
        entries.size
      end

      private

      # Ensure the parent directory of the log file exists.
      #
      # @return [void]
      def ensure_directory!
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir)
      end
    end
  end
end
