# frozen_string_literal: true

require 'json'
require_relative 'store'

module Woods
  module SessionTracer
    # SolidCache-backed session store using atomic counters and bounded slots.
    class SolidCacheStore < Store # rubocop:disable Metrics/ClassLength
      KEY_PREFIX = 'woods:session:'
      INDEX_PREFIX = 'woods:session_index'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000
      INDEX_SLOT_MULTIPLIER = 2

      class AtomicIncrementRequired < Woods::Error; end
      class BackendWriteError < Woods::Error; end

      # @param cache [ActiveSupport::Cache::Store] A cache with atomic +increment+
      # @param expires_in [Integer, nil] Expiry time in seconds (nil = no expiry)
      def initialize(cache:, expires_in: nil, max_sessions: DEFAULT_MAX_SESSIONS,
                     max_requests_per_session: DEFAULT_MAX_REQUESTS)
        super()
        unless cache.respond_to?(:increment)
          raise ArgumentError, 'SolidCacheStore requires a backend with atomic #increment'
        end

        @cache = cache
        @expires_in = expires_in
        @max_sessions = positive_integer!(:max_sessions, max_sessions)
        @max_requests_per_session = positive_integer!(:max_requests_per_session, max_requests_per_session)
        @index_slots = @max_sessions * INDEX_SLOT_MULTIPLIER
      end

      # Allocate a monotonic sequence and publish one immutable-sequence slot.
      def record(session_id, request_data)
        normalized_record = JSON.parse(JSON.generate(request_data))
        index_sequence = increment!(index_sequence_key)
        sequence = increment!(sequence_key(session_id))
        index_current = publish_current_slot?(
          index_slot_key(index_sequence), index_sequence, @index_slots, index_sequence_key,
          JSON.generate('sequence' => index_sequence, 'session_id' => session_id.to_s)
        )
        return unless index_current

        key = record_key(session_id, sequence)
        publish_current_slot?(key, sequence, @max_requests_per_session, sequence_key(session_id),
                              JSON.generate('sequence' => sequence, 'record' => normalized_record))
        @cache.delete(key) if stale_sequence?(index_sequence, @index_slots, index_sequence_key)
        nil
      end

      # Read the current bounded sequence window, skipping allocation gaps.
      def read(session_id)
        sequence = counter_value(sequence_key(session_id))
        return [] unless sequence.positive?

        sequence_window(sequence, @max_requests_per_session).filter_map do |expected|
          parse_slot(@cache.read(record_key(session_id, expected)), expected, 'record')
        end
      end

      # Reconstruct recent unique sessions from the bounded global event ring.
      def sessions(limit: 20)
        sequence = counter_value(index_sequence_key)
        summaries = []
        indexed_session_ids(sequence).each do |session_id|
          requests = read(session_id)
          next if requests.empty?

          summaries << session_summary(session_id, requests)
          break if summaries.size >= [limit, @max_sessions].min
        end
        summaries
      end

      def clear(session_id)
        cleared_through = increment!(sequence_key(session_id), @max_requests_per_session) -
                          @max_requests_per_session
        sequence_window(cleared_through, @max_requests_per_session).each do |slot_sequence|
          @cache.delete(record_key(session_id, slot_sequence))
        end
        nil
      end

      def clear_all
        cleared_through = increment!(index_sequence_key, @index_slots) - @index_slots
        indexed_session_ids(cleared_through).each { |session_id| clear(session_id) }
        sequence_window(cleared_through, @index_slots).each do |slot_sequence|
          @cache.delete(index_slot_key(slot_sequence))
        end
        nil
      end

      private

      def increment!(key, amount = 1)
        value = @cache.increment(key, amount, **write_options)
        return value if value.is_a?(Integer) && value.positive?

        message = "SolidCache backend atomic #increment failed for #{key.inspect}; " \
                  'configure a backend that supports increment'
        raise AtomicIncrementRequired, message
      rescue NotImplementedError, NoMethodError => e
        raise AtomicIncrementRequired,
              "SolidCacheStore requires a working backend atomic #increment (#{e.class}: #{e.message})"
      end

      def write!(key, value)
        return if @cache.write(key, value, **write_options)

        raise BackendWriteError, "SolidCache backend failed to write #{key.inspect}"
      end

      def publish_current_slot?(key, sequence, window_size, counter_key, value)
        write!(key, value)
        @cache.delete(slot_key_before(key, sequence, window_size)) if sequence > window_size

        if stale_sequence?(sequence, window_size, counter_key)
          @cache.delete(key)
          false
        else
          true
        end
      end

      def slot_key_before(key, sequence, window_size)
        key.sub(/:\d+\z/, ":#{sequence - window_size}")
      end

      def write_options
        @expires_in ? { expires_in: @expires_in } : {}
      end

      def sequence_window(sequence, size)
        first = [sequence - size + 1, 1].max
        first..sequence
      end

      def parse_slot(raw, expected_sequence, field)
        return unless raw

        payload = JSON.parse(raw)
        payload[field] if payload['sequence'] == expected_sequence
      rescue JSON::ParserError, TypeError
        nil
      end

      def counter_value(key)
        Integer(@cache.read(key) || 0)
      rescue ArgumentError, TypeError
        0
      end

      def indexed_session_ids(sequence)
        seen = {}
        sequence_window(sequence, @index_slots).reverse_each.filter_map do |expected|
          session_id = parse_slot(@cache.read(index_slot_key(expected)), expected, 'session_id')
          next unless session_id
          next if seen[session_id]

          seen[session_id] = true
          session_id
        end
      end

      def stale_sequence?(sequence, window_size, counter_key)
        sequence <= counter_value(counter_key) - window_size
      end

      def sequence_key(session_id)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:sequence"
      end

      def record_key(session_id, sequence)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:record:#{sequence}"
      end

      def index_sequence_key
        "#{INDEX_PREFIX}:sequence"
      end

      def index_slot_key(sequence)
        "#{INDEX_PREFIX}:slot:#{sequence}"
      end

      def positive_integer!(name, value)
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive Integer"
      end
    end
  end
end
