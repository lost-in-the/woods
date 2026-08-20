# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'solid_cache_coordination'
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
      RECORD_PUBLISH_ATTEMPTS = 32

      class AtomicIncrementRequired < Woods::Error; end
      class BackendWriteError < Woods::Error; end
      class DirectoryContentionError < Woods::Error; end

      DirectorySlot = Struct.new(:slot, :raw, :membership, keyword_init: true)

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
        @backend = solid_cache_backend? ? SolidCacheCoordination.new(cache) : cache
      end

      # Admit the session, allocate a monotonic sequence, and publish one record.
      def record(session_id, request_data)
        normalized_record = JSON.parse(JSON.generate(request_data))
        membership = owned_membership(session_id) || admit_session(session_id)
        return unless membership

        sequence_key = slot_sequence_key(membership['slot'])
        sequence = increment!(sequence_key)
        key = record_key(membership, sequence)
        payload = JSON.generate('sequence' => sequence, 'token' => membership['token'],
                                'record' => normalized_record)
        published = publish_current_slot?(key, sequence, @max_requests_per_session, sequence_key, payload)
        if published && current_membership?(membership)
          refresh_activity!(membership)
          return if current_membership?(membership)
        end

        atomic_delete_if_equal(key, payload)
        @backend.delete(activity_key(membership))
        nil
      end

      # Read the current bounded sequence window, skipping allocation gaps.
      def read(session_id)
        membership = owned_membership(session_id)
        return [] unless membership

        sequence = counter_value(slot_sequence_key(membership['slot']))
        first_sequence = [sequence - @max_requests_per_session + 1, membership['record_floor'] + 1, 1].max
        return [] if first_sequence > sequence

        records = (first_sequence..sequence).filter_map do |expected|
          parse_record(@backend.read(record_key(membership, expected)), membership, expected)
        end
        return [] unless current_membership?(membership)

        records
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
        directory_slots.each do |entry|
          if entry.membership
            retire_membership(entry.membership)
          elsif entry.raw
            atomic_delete_if_equal(index_slot_key(entry.slot), entry.raw)
          end
        end
        nil
      end

      private

      def increment!(key, amount = 1)
        ensure_counter_present!(key)
        value = @backend.increment(key, amount)
        return value if value.is_a?(Integer) && value.positive?

        message = "SolidCache backend atomic #increment failed for #{key.inspect}; " \
                  'configure a backend that supports increment'
        raise AtomicIncrementRequired, message
      rescue NotImplementedError, NoMethodError => e
        raise AtomicIncrementRequired,
              "SolidCacheStore requires a working backend atomic #increment (#{e.class}: #{e.message})"
      end

      def ensure_counter_present!(key)
        return atomic_write_if_absent(key, 0) unless @backend.respond_to?(:ensure_present)
        return if @backend.ensure_present(key, 0)

        raise BackendWriteError, "SolidCache backend could not initialize counter #{key.inspect}"
      end

      def write!(key, value)
        return if @backend.write(key, value, **write_options)

        raise BackendWriteError, "SolidCache backend failed to write #{key.inspect}"
      end

      def publish_current_slot?(key, sequence, window_size, counter_key, value)
        return false unless write_newer_slot(key, sequence, value)

        if stale_sequence?(sequence, window_size, counter_key)
          atomic_delete_if_equal(key, value)
          false
        else
          true
        end
      end

      def write_newer_slot(key, sequence, value)
        RECORD_PUBLISH_ATTEMPTS.times do
          raw = @backend.read(key)
          stored_sequence = payload_sequence(raw)
          return false if stored_sequence && stored_sequence >= sequence

          next if raw && !atomic_delete_if_equal(key, raw)
          return true if atomic_write_if_absent(key, value, **write_options)

          Thread.pass
        end

        raise BackendWriteError, "SolidCache backend could not publish #{key.inspect} after " \
                                 "#{RECORD_PUBLISH_ATTEMPTS} attempts"
      end

      def write_options
        @expires_in ? { expires_in: @expires_in } : {}
      end

      def parse_record(raw, membership, expected_sequence)
        return unless raw

        payload = JSON.parse(raw)
        return unless payload.is_a?(Hash)
        return unless payload['token'] == membership['token'] && payload['sequence'] == expected_sequence

        payload['record']
      rescue JSON::ParserError, TypeError
        nil
      end

      def payload_sequence(raw)
        return unless raw

        payload = JSON.parse(raw)
        payload['sequence'] if payload.is_a?(Hash) && payload['sequence'].is_a?(Integer)
      rescue JSON::ParserError, TypeError
        nil
      end

      def counter_value(key)
        Integer(@backend.read(key) || 0)
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
          slots = directory_slots
          membership = claim_reclaimable_slot(attributes, slots)
          return membership if membership

          victim = oldest_active_membership(slots.filter_map(&:membership))
          retire_membership(victim) if victim
        end

        raise DirectoryContentionError,
              "SolidCacheStore could not claim a directory slot after #{DIRECTORY_CLAIM_ATTEMPTS} attempts " \
              "for #{attributes['session_id'].inspect}; retry the record operation or investigate backend contention"
      end

      def claim_reclaimable_slot(attributes, slots)
        slots.each do |entry|
          occupant = entry.membership
          next if occupant && active_current_membership?(occupant)

          if occupant
            retire_membership(occupant)
          elsif entry.raw
            atomic_delete_if_equal(index_slot_key(entry.slot), entry.raw)
          end
          membership = attributes.merge(
            'slot' => entry.slot,
            'record_floor' => counter_value(slot_sequence_key(entry.slot))
          )
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
        directory_slots.filter_map(&:membership).select { |membership| active_current_membership?(membership) }
                       .sort_by { |membership| membership['sequence'] }
      end

      def directory_slots
        @max_sessions.times.map do |slot|
          raw = @backend.read(index_slot_key(slot))
          DirectorySlot.new(slot: slot, raw: raw, membership: parse_membership(raw, expected_slot: slot))
        end
      end

      def owned_membership(session_id)
        membership = active_membership(session_id)
        membership if membership && indexed_membership?(membership)
      end

      def active_membership(session_id)
        membership = stored_membership(session_id)
        return membership unless membership && @expires_in
        return membership if @backend.read(activity_key(membership))

        retire_membership(membership)
        nil
      end

      def stored_membership(session_id)
        parse_membership(@backend.read(active_key(session_id)))
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
        return false unless membership.is_a?(Hash)

        valid_membership_identity?(membership) && valid_membership_position?(membership)
      end

      def valid_membership_identity?(membership)
        membership['sequence'].is_a?(Integer) && membership['sequence'].positive? &&
          membership['session_id'].is_a?(String) && membership['token'].is_a?(String)
      end

      def valid_membership_position?(membership)
        membership['slot'].is_a?(Integer) && membership['slot'].between?(0, @max_sessions - 1) &&
          membership['record_floor'].is_a?(Integer) && membership['record_floor'] >= 0
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
        @backend.delete(activity_key(membership))
        cleanup_generation(session_id, membership['token'])
        release_directory_slot(membership)
      end

      def refresh_activity!(membership)
        return unless @expires_in

        write!(activity_key(membership), true)
      end

      def cleanup_generation(session_id, generation)
        @max_requests_per_session.times do |slot|
          @backend.delete(record_ring_key(session_id, generation, slot + 1))
        end
      end

      def indexed_membership?(membership)
        raw = @backend.read(index_slot_key(membership['slot']))
        parse_membership(raw, expected_slot: membership['slot']) == membership
      end

      def release_directory_slot(membership)
        atomic_delete_if_equal(index_slot_key(membership['slot']), serialized_membership(membership))
      end

      def atomic_delete_if_equal(key, expected)
        @backend.delete_if_equal(key, expected)
      end

      def atomic_write_if_absent(key, value, **options)
        @backend.write_if_absent(key, value, **options)
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

      def slot_sequence_key(slot)
        "#{INDEX_PREFIX}:slot:#{slot}:sequence"
      end

      def record_key(membership, sequence)
        ring_slot = ((sequence - 1) % @max_requests_per_session) + 1
        record_ring_key(membership['session_id'], membership['token'], ring_slot)
      end

      def record_ring_key(session_id, generation, ring_slot)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}:generation:#{generation}:record:#{ring_slot}"
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
