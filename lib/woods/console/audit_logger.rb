# frozen_string_literal: true

require 'json'
require 'fileutils'

module CodebaseIndex
  module Console
    # Logs all Tier 4 tool invocations to a JSONL file.
    #
    # Each line is a JSON object with: tool name, params, timestamp,
    # confirmation status, and result summary.
    #
    # @example
    #   logger = AuditLogger.new(path: 'log/console_audit.jsonl')
    #   logger.log(tool: 'console_eval', params: { code: '1+1' },
    #              confirmed: true, result_summary: '2')
    #   logger.entries # => [{ "tool" => "console_eval", ... }]
    #
    class AuditLogger
      # @param path [String] Path to the JSONL audit log file
      def initialize(path:)
        @path = path
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
          params: params,
          confirmed: confirmed,
          result_summary: result_summary,
          timestamp: Time.now.utc.iso8601
        }

        File.open(@path, 'a') { |f| f.puts(JSON.generate(entry)) }
      end

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
