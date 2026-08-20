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
      end

      # Admit the session, allocate a monotonic sequence, and publish one record.
      def record(session_id, request_data)
        normalized_record = JSON.parse(JSON.generate(request_data))
        membership = active_membership(session_id) || admit_session(session_id)
        return unless membership

        sequence_key = sequence_key(session_id, membership['sequence'])
        sequence = increment!(sequence_key)
        key = record_key(session_id, membership['sequence'], sequence)
        published = publish_current_slot?(key, sequence, @max_requests_per_session, sequence_key,
                                          JSON.generate('sequence' => sequence, 'record' => normalized_record))
        @cache.delete(key) unless published && current_membership?(membership)
        nil
      end

      # Read the current bounded sequence window, skipping allocation gaps.
      def read(session_id)
        membership = active_membership(session_id)
        return [] unless membership

        generation = membership['sequence']
        sequence = counter_value(sequence_key(session_id, generation))
        return [] unless sequence.positive?

        sequence_window(sequence, @max_requests_per_session).filter_map do |expected|
          parse_slot(@cache.read(record_key(session_id, generation, expected)), expected, 'record')
        end
      end

      # List the bounded active-session set, newest admission first.
      def sessions(limit: 20)
        active_memberships.reverse_each.filter_map do |membership|
          session_id = membership['session_id']
          requests = read(session_id)
          session_summary(session_id, requests) unless requests.empty?
        end.first([limit, @max_sessions].min)
      end

      def clear(session_id)
        membership = active_membership(session_id)
        retire_membership(membership) if membership
        nil
      end

      def clear_all
        cleared_through = increment!(index_sequence_key, @max_sessions) - @max_sessions
        indexed_memberships(cleared_through, current_only: false).each { |membership| retire_membership(membership) }
        sequence_window(cleared_through, cleared_through).each do |slot_sequence|
          @cache.delete(index_slot_key(slot_sequence))
        end
        nil
      end

      private

      def increment!(key, amount = 1)
        @cache.write(key, 0, unless_exist: true, **write_options)
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

      def admit_session(session_id)
        index_sequence = increment!(index_sequence_key)
        membership = { 'sequence' => index_sequence, 'session_id' => session_id.to_s }
        claimed = @cache.write(active_key(session_id), JSON.generate(membership), unless_exist: true, **write_options)
        return active_membership(session_id) unless claimed

        write!(index_slot_key(index_sequence), JSON.generate(membership))
        unless current_membership?(membership)
          retire_membership(membership)
          return active_membership(session_id)
        end
        if stale_index_sequence?(index_sequence)
          retire_membership(membership)
          return
        end

        enforce_active_bound
        active_membership(session_id)
      end

      def enforce_active_bound
        memberships = active_memberships
        overflow = memberships.size - @max_sessions
        memberships.first(overflow).each { |membership| retire_membership(membership) } if overflow.positive?
      end

      def active_memberships
        indexed_memberships(counter_value(index_sequence_key))
      end

      def indexed_memberships(sequence, current_only: true)
        seen = {}
        sequence_window(sequence, sequence).filter_map do |expected|
          membership = parse_membership(@cache.read(index_slot_key(expected)), expected)
          next unless membership
          next if current_only && !current_membership?(membership)

          identity = [membership['session_id'], membership['sequence']]
          next if seen[identity]

          seen[identity] = true
          membership
        end
      end

      def active_membership(session_id)
        parse_membership(@cache.read(active_key(session_id)))
      end

      def parse_membership(raw, expected_sequence = nil)
        return unless raw

        membership = JSON.parse(raw)
        return unless valid_membership?(membership)
        return if expected_sequence && membership['sequence'] != expected_sequence

        membership
      rescue JSON::ParserError, TypeError
        nil
      end

      def valid_membership?(membership)
        membership['sequence'].is_a?(Integer) && membership['sequence'].positive? &&
          membership['session_id'].is_a?(String)
      end

      def current_membership?(membership)
        active_membership(membership['session_id']) == membership
      end

      def retire_membership(membership)
        session_id = membership['session_id']
        @cache.delete(active_key(session_id)) if current_membership?(membership)
        cleanup_generation(session_id, membership['sequence'])
        @cache.delete(index_slot_key(membership['sequence'])) if indexed_membership?(membership)
      end

      def cleanup_generation(session_id, generation)
        key = sequence_key(session_id, generation)
        sequence = counter_value(key)
        sequence_window(sequence, @max_requests_per_session).each do |slot_sequence|
          @cache.delete(record_key(session_id, generation, slot_sequence))
        end
        @cache.delete(key)
      end

      def indexed_membership?(membership)
        parse_membership(@cache.read(index_slot_key(membership['sequence'])), membership['sequence']) == membership
      end

      def stale_sequence?(sequence, window_size, counter_key)
        sequence <= counter_value(counter_key) - window_size
      end

      def stale_index_sequence?(sequence)
        stale_sequence?(sequence, @max_sessions, index_sequence_key)
      end

      def active_key(session_id)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:active"
      end

      def sequence_key(session_id, generation)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:generation:#{generation}:sequence"
      end

      def record_key(session_id, generation, sequence)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:generation:#{generation}:record:#{sequence}"
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
