# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'store'

module Woods
  module SessionTracer
    # SolidCache-backed session store using atomic counters and bounded slots.
    class SolidCacheStore < Store # rubocop:disable Metrics/ClassLength
      KEY_PREFIX = 'woods:session:'
      INDEX_PREFIX = 'woods:session_index'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000
      DIRECTORY_CLAIM_ATTEMPTS = 3

      class AtomicIncrementRequired < Woods::Error; end
      class BackendWriteError < Woods::Error; end

      # @param cache [ActiveSupport::Cache::Store] A Solid Cache store, or a cache with atomic
      #   +increment+, +write_if_absent+, and +delete_if_equal+ operations
      # @param expires_in [Integer, nil] Expiry time in seconds (nil = no expiry)
      def initialize(cache:, expires_in: nil, max_sessions: DEFAULT_MAX_SESSIONS,
                     max_requests_per_session: DEFAULT_MAX_REQUESTS)
        super()
        @cache = cache
        unless cache.respond_to?(:increment)
          raise ArgumentError, 'SolidCacheStore requires a backend with atomic #increment'
        end
        unless cache.respond_to?(:write_if_absent) || solid_cache_backend?
          raise ArgumentError,
                'SolidCacheStore requires atomic #write_if_absent or a direct SolidCache::Store backend'
        end
        unless cache.respond_to?(:delete_if_equal) || solid_cache_backend?
          raise ArgumentError,
                'SolidCacheStore requires atomic #delete_if_equal or a direct SolidCache::Store backend'
        end

        @expires_in = expires_in
        @max_sessions = positive_integer!(:max_sessions, max_sessions)
        @max_requests_per_session = positive_integer!(:max_requests_per_session, max_requests_per_session)
      end

      # Admit the session, allocate a monotonic sequence, and publish one record.
      def record(session_id, request_data)
        normalized_record = JSON.parse(JSON.generate(request_data))
        membership = active_membership(session_id) || admit_session(session_id)
        return unless membership

        generation = membership['token']
        sequence_key = sequence_key(session_id, generation)
        sequence = increment!(sequence_key)
        key = record_key(session_id, generation, sequence)
        published = publish_current_slot?(key, sequence, @max_requests_per_session, sequence_key,
                                          JSON.generate('sequence' => sequence, 'record' => normalized_record))
        if published && current_membership?(membership)
          refresh_activity!(membership)
          return if current_membership?(membership)
        end

        @cache.delete(key)
        @cache.delete(activity_key(membership))
        nil
      end

      # Read the current bounded sequence window, skipping allocation gaps.
      def read(session_id)
        membership = active_membership(session_id)
        return [] unless membership

        generation = membership['token']
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
        increment!(index_sequence_key, @max_sessions)
        directory_memberships.compact.each { |membership| retire_membership(membership) }
        nil
      end

      private

      def increment!(key, amount = 1)
        atomic_write_if_absent(key, 0)
        value = @cache.increment(key, amount)
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
        membership = claim_directory_slot(
          'sequence' => index_sequence,
          'session_id' => session_id.to_s,
          'token' => SecureRandom.hex(16)
        )
        return unless membership

        unless atomic_write_if_absent(active_key(session_id), serialized_membership(membership))
          release_directory_slot(membership)
          return active_membership(session_id)
        end
        refresh_activity!(membership)
        finalize_admission(membership)
      end

      def finalize_admission(membership)
        unless current_membership?(membership)
          retire_membership(membership)
          return active_membership(membership['session_id'])
        end
        if stale_index_sequence?(membership['sequence'])
          retire_membership(membership)
          return
        end

        active_membership(membership['session_id'])
      end

      def claim_directory_slot(attributes)
        DIRECTORY_CLAIM_ATTEMPTS.times do
          memberships = directory_memberships
          membership = claim_reclaimable_slot(attributes, memberships)
          return membership if membership

          victim = oldest_active_membership(memberships)
          retire_membership(victim) if victim
        end
        nil
      end

      def claim_reclaimable_slot(attributes, memberships)
        memberships.each_with_index do |occupant, slot|
          next if occupant && active_current_membership?(occupant)

          retire_membership(occupant) if occupant
          membership = attributes.merge('slot' => slot)
          return membership if claim_directory_slot?(membership)
        end
        nil
      end

      def oldest_active_membership(memberships)
        memberships.compact.select { |membership| active_current_membership?(membership) }
                   .min_by { |membership| membership['sequence'] }
      end

      def claim_directory_slot?(membership)
        key = index_slot_key(membership['slot'])
        written = atomic_write_if_absent(key, serialized_membership(membership))
        written && indexed_membership?(membership)
      end

      def active_memberships
        directory_memberships.select { |membership| membership && active_current_membership?(membership) }
                             .sort_by { |membership| membership['sequence'] }
      end

      def directory_memberships
        @max_sessions.times.map do |slot|
          parse_membership(@cache.read(index_slot_key(slot)), expected_slot: slot)
        end
      end

      def active_membership(session_id)
        membership = stored_membership(session_id)
        return membership unless membership && @expires_in
        return membership if @cache.read(activity_key(membership))

        retire_membership(membership)
        nil
      end

      def stored_membership(session_id)
        parse_membership(@cache.read(active_key(session_id)))
      end

      def parse_membership(raw, expected_slot: nil)
        return unless raw

        membership = JSON.parse(raw)
        return unless valid_membership?(membership)
        return if expected_slot && membership['slot'] != expected_slot

        membership
      rescue JSON::ParserError, TypeError
        nil
      end

      def valid_membership?(membership)
        membership['sequence'].is_a?(Integer) && membership['sequence'].positive? &&
          membership['session_id'].is_a?(String) && membership['token'].is_a?(String) &&
          membership['slot'].is_a?(Integer) && membership['slot'].between?(0, @max_sessions - 1)
      end

      def current_membership?(membership)
        stored_membership(membership['session_id']) == membership && indexed_membership?(membership)
      end

      def active_current_membership?(membership)
        active_membership(membership['session_id']) == membership && indexed_membership?(membership)
      end

      def retire_membership(membership)
        session_id = membership['session_id']
        atomic_delete_if_equal(active_key(session_id), serialized_membership(membership))
        @cache.delete(activity_key(membership))
        cleanup_generation(session_id, membership['token'])
        release_directory_slot(membership)
      end

      def refresh_activity!(membership)
        return unless @expires_in

        write!(activity_key(membership), true)
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
        raw = @cache.read(index_slot_key(membership['slot']))
        parse_membership(raw, expected_slot: membership['slot']) == membership
      end

      def release_directory_slot(membership)
        atomic_delete_if_equal(index_slot_key(membership['slot']), serialized_membership(membership))
      end

      def atomic_delete_if_equal(key, expected)
        if @cache.respond_to?(:delete_if_equal)
          @cache.delete_if_equal(key, expected)
        else
          solid_cache_delete_if_equal(key, expected)
        end
      end

      def atomic_write_if_absent(key, value)
        if @cache.respond_to?(:write_if_absent)
          @cache.write_if_absent(key, value)
        else
          solid_cache_write_if_absent?(key, value)
        end
      end

      def solid_cache_write_if_absent?(key, value)
        options = @cache.send(:merged_options, nil)
        normalized_key = @cache.send(:normalize_key, key, options)
        entry_class = ::SolidCache::Entry
        entry = ActiveSupport::Cache::Entry.new(value)
        payload = @cache.send(:serialize_entry, entry, **options)
        attributes = entry_class.send(:add_key_hash_and_byte_size, [{ key: normalized_key, value: payload }]).first

        entry_class.insert_all([attributes], unique_by: entry_class.send(:upsert_unique_by))
        stored = entry_class.read(normalized_key)
        @cache.send(:deserialize_entry, stored, **options)&.value == value
      end

      def solid_cache_delete_if_equal(key, expected)
        options = @cache.send(:merged_options, nil)
        normalized_key = @cache.send(:normalize_key, key, options)
        entry_class = ::SolidCache::Entry
        key_hash = entry_class.send(:key_hash_for, normalized_key)
        deleted = false

        entry_class.transaction do
          raw_key, raw_value = entry_class.lock.where(key_hash: key_hash).pick(:key, :value)
          next unless raw_key == normalized_key

          entry = @cache.send(:deserialize_entry, raw_value, **options)
          next unless entry&.value == expected

          @cache.delete(key)
          deleted = true
        end
        deleted
      end

      def solid_cache_backend?
        defined?(::SolidCache::Store) && @cache.is_a?(::SolidCache::Store)
      end

      def serialized_membership(membership)
        JSON.generate(membership)
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

      def activity_key(membership)
        "#{KEY_PREFIX}#{sanitize_session_id(membership['session_id'])}:generation:#{membership['token']}:activity"
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

      def index_slot_key(slot)
        "#{INDEX_PREFIX}:slot:#{slot}"
      end

      def positive_integer!(name, value)
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive Integer"
      end
    end
  end
end
