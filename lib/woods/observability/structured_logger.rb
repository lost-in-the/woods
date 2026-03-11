# frozen_string_literal: true

require 'json'
require 'time'

module CodebaseIndex
  module Observability
    # Structured JSON logger that writes one JSON object per line.
    #
    # Each log entry includes a timestamp, level, event name, and any
    # additional data passed as keyword arguments.
    #
    # @example
    #   logger = StructuredLogger.new(output: $stderr)
    #   logger.info('extraction.complete', units: 42, duration_ms: 1200)
    #   # => {"timestamp":"2026-02-15T12:00:00Z","level":"info",
    #   #     "event":"extraction.complete","units":42,"duration_ms":1200}
    #
    class StructuredLogger
      # @param output [IO] Output stream (default: $stderr)
      def initialize(output: $stderr)
        @output = output
      end

      # @!method info(event, **data)
      #   Log at info level.
      #   @param event [String] Event name
      #   @param data [Hash] Additional structured data
      # @!method warn(event, **data)
      #   Log at warn level.
      # @!method error(event, **data)
      #   Log at error level.
      # @!method debug(event, **data)
      #   Log at debug level.
      %w[info warn error debug].each do |level|
        define_method(level) { |event, **data| write_entry(level, event, data) }
      end

      private

      # Write a single JSON log line.
      #
      # @param level [String] Log level
      # @param event [String] Event name
      # @param data [Hash] Additional data
      def write_entry(level, event, data)
        entry = {
          timestamp: Time.now.utc.iso8601,
          level: level,
          event: event
        }.merge(data)

        @output.puts(JSON.generate(entry))
      end
    end
  end
end
