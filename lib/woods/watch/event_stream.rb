# frozen_string_literal: true

require 'json'

module Woods
  module Watch
    # Bounded framing plus the guardian-issued child identity used for cleanup.
    class EventStream
      MAX_BYTES = 4096

      def initialize(reader:, guardian:, launcher:, attempt:)
        @reader = reader
        @guardian = guardian
        @identity = { 'launcher' => launcher, 'attempt' => attempt, 'pid' => guardian, 'event' => 'spawned' }
        @buffer = +''
      end

      attr_reader :child_pid

      def read
        records = []
        return records if @reader.closed?

        16.times do
          part = @reader.read_nonblock(MAX_BYTES, exception: false)
          break if part == :wait_readable
          return finish(records) if part.nil?

          @buffer << part
          drain_lines(records)
        end
        records
      end

      def eof?
        @eof == true
      end

      private

      def finish(records)
        @eof = true
        raise ArgumentError, 'truncated Woods lifecycle record' unless @buffer.empty?

        records
      end

      def drain_lines(records)
        while @buffer.include?("\n")
          record = @buffer.slice!(0..@buffer.index("\n"))
          raise ArgumentError, 'oversized Woods lifecycle record' if record.bytesize > MAX_BYTES

          remember_child(record)
          records << record
        end
        raise ArgumentError, 'oversized Woods lifecycle record' if @buffer.bytesize > MAX_BYTES
      end

      def remember_child(line)
        record = JSON.parse(line)
        return unless record.is_a?(Hash) && @identity.all? { |key, value| record[key] == value }

        child = record['child_pid']
        @child_pid = child if child.is_a?(Integer) && child.positive?
      rescue JSON::ParserError
        nil # The lifecycle validator reports malformed records.
      end
    end
  end
end
