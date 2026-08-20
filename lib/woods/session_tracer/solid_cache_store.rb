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
        raise ArgumentError, 'SolidCacheStore requires a backend with atomic #increment' unless cache.respond_to?(:increment)

        @cache = cache
        @expires_in = expires_in
        @max_sessions = positive_integer!(:max_sessions, max_sessions)
        @max_requests_per_session = positive_integer!(:max_requests_per_session, max_requests_per_session)
        @index_slots = @max_sessions * INDEX_SLOT_MULTIPLIER
      end

      # Allocate a monotonic sequence and publish one immutable-sequence slot.
      def record(session_id, request_data)
        JSON.generate(request_data)
        sequence = increment!(sequence_key(session_id))
        publish_slot(record_key(session_id, sequence), sequence, @max_requests_per_session,
                     sequence_key(session_id), JSON.generate('sequence' => sequence, 'record' => request_data))

        index_sequence = increment!(index_sequence_key)
        publish_slot(index_slot_key(index_sequence), index_sequence, @index_slots, index_sequence_key,
                     JSON.generate('sequence' => index_sequence, 'session_id' => session_id.to_s))
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
        ids = sequence_window(sequence, @index_slots).reverse_each.filter_map do |expected|
          parse_slot(@cache.read(index_slot_key(expected)), expected, 'session_id')
        end.uniq.first(@max_sessions)

        ids.filter_map do |session_id|
          requests = read(session_id)
          session_summary(session_id, requests) unless requests.empty?
        end.first(limit)
      end

      def clear(session_id)
        sequence = counter_value(sequence_key(session_id))
        @cache.delete(sequence_key(session_id))
        sequence_window(sequence, @max_requests_per_session).each do |slot_sequence|
          @cache.delete(record_key(session_id, slot_sequence))
        end
        nil
      end

      def clear_all
        sessions(limit: @max_sessions).each { |entry| clear(entry.fetch('session_id')) }
        index_sequence = counter_value(index_sequence_key)
        @cache.delete(index_sequence_key)
        sequence_window(index_sequence, @index_slots).each { |slot_sequence| @cache.delete(index_slot_key(slot_sequence)) }
        nil
      end

      private

      def increment!(key)
        value = @cache.increment(key, 1, **write_options)
        return value if value.is_a?(Integer) && value.positive?

        raise AtomicIncrementRequired,
              "SolidCache backend atomic #increment failed for #{key.inspect}; configure a backend that supports increment"
      rescue NotImplementedError, NoMethodError => e
        raise AtomicIncrementRequired,
              "SolidCacheStore requires a working backend atomic #increment (#{e.class}: #{e.message})"
      end

      def write!(key, value)
        return if @cache.write(key, value, **write_options)

        raise BackendWriteError, "SolidCache backend failed to write #{key.inspect}"
      end

      def publish_slot(key, sequence, window_size, counter_key, value)
        write!(key, value)
        @cache.delete(slot_key_before(key, sequence, window_size)) if sequence > window_size

        latest = counter_value(counter_key)
        @cache.delete(key) if sequence <= latest - window_size
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
