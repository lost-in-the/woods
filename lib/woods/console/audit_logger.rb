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

        entry = {
          tool: tool,
          params: redact(truncate_deep(params)),
          confirmed: confirmed,
          result_summary: redact(truncate_value(result_summary)),
          timestamp: Time.now.utc.iso8601
        }

        File.open(@path, 'a') { |f| f.puts(JSON.generate(entry)) }
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

      public

      # Read all audit entries.
      #
      # @return [Array<Hash>] Parsed JSONL entries
      def entries
        return [] unless File.exist?(@path)

        File.readlines(@path).filter_map do |line|
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
