# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'solid_cache_coordination'
require_relative 'store'

module Woods
  module SessionTracer
    # SolidCache-backed session store using atomic counters and bounded slots.
    #
    # Storage layout, all bounded by construction:
    # - one global epoch counter that fences +clear_all+
    # - one global admission counter that orders memberships
    # - +max_sessions+ directory slots, each with a permanent record counter
    # - +max_sessions+ x +max_requests_per_session+ ring record keys, keyed by
    #   directory slot (never by session or token), so a writer that crashes
    #   after publishing cannot grow storage past the fixed keyspace
    #
    # Counters recover from observable evidence (ring payload sequences,
    # directory memberships) when missing or corrupt, and fail closed with
    # BackendWriteError when the backend cannot hold the recovered value.
    class SolidCacheStore < Store # rubocop:disable Metrics/ClassLength
      KEY_PREFIX = 'woods:session:'
      INDEX_PREFIX = 'woods:session_index'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000
      DIRECTORY_CLAIM_ATTEMPTS = 3
      RECORD_PUBLISH_ATTEMPTS = 32
      READ_ATTEMPTS = 8
      COUNTER_RECOVERY_ATTEMPTS = 3

      class AtomicIncrementRequired < Woods::Error; end
      class BackendWriteError < Woods::Error; end
      class DirectoryContentionError < Woods::Error; end
      class ReadContentionError < Woods::Error; end

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
        epoch = current_epoch
        membership = owned_membership(session_id, epoch) || admit_session(session_id, epoch)
        return unless membership

        publish_record(membership, normalized_record)
      end

      # Read one completed bounded sequence window. Retries when a concurrent
      # overwrite moves the ring mid-read so a mixed window is never returned.
      def read(session_id)
        READ_ATTEMPTS.times do
          records = read_snapshot(session_id)
          return records if records
        end

        raise ReadContentionError,
              "SolidCacheStore could not obtain a stable read for #{session_id.inspect} after " \
              "#{READ_ATTEMPTS} attempts; retry once backend write contention subsides"
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
        increment!(epoch_key)
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

      def publish_record(membership, normalized_record)
        slot = membership['slot']
        sequence_key = slot_sequence_key(slot)
        sequence = increment!(sequence_key, slot: slot)
        key = record_key(slot, sequence)
        payload = JSON.generate('sequence' => sequence, 'token' => membership['token'],
                                'record' => normalized_record)
        published = publish_current_slot?(key, sequence, sequence_key, slot, payload)
        epoch_now = current_epoch
        if published && current_membership?(membership, epoch_now)
          refresh_activity!(membership)
          return if current_membership?(membership, epoch_now)
        end

        atomic_delete_if_equal(key, payload)
        @backend.delete(activity_key(membership))
        nil
      end

      # One read attempt: returns records for a stable window, [] for no
      # session, or nil when the window moved and the caller must retry.
      def read_snapshot(session_id)
        epoch = current_epoch
        membership = owned_membership(session_id, epoch)
        return [] unless membership

        slot = membership['slot']
        sequence_key = slot_sequence_key(slot)
        sequence = counter_value(sequence_key, slot: slot)
        first_sequence = [sequence - @max_requests_per_session + 1, membership['record_floor'] + 1, 1].max
        return [] if first_sequence > sequence

        records = (first_sequence..sequence).filter_map do |expected|
          parse_record(@backend.read(record_key(slot, expected)), membership, expected)
        end
        return unless counter_value(sequence_key, slot: slot) == sequence
        return [] unless current_membership?(membership, epoch)

        records
      end

      def increment!(key, amount = 1, slot: nil)
        ensure_counter_present!(key, slot: slot)
        value = @backend.increment(key, amount)
        return value if value.is_a?(Integer) && value.positive?

        message = "SolidCache backend atomic #increment failed for #{key.inspect}; " \
                  'configure a backend that supports increment'
        raise AtomicIncrementRequired, message
      rescue NotImplementedError, NoMethodError => e
        raise AtomicIncrementRequired,
              "SolidCacheStore requires a working backend atomic #increment (#{e.class}: #{e.message})"
      end

      def ensure_counter_present!(key, slot: nil)
        return if integer_value(@backend.read(key))

        counter_value(key, slot: slot)
      end

      # Read a counter, recovering from evidence when it is missing or corrupt.
      def counter_value(key, slot: nil)
        raw = @backend.read(key)
        value = integer_value(raw)
        return value if value

        recover_counter!(key, raw, slot: slot)
      end

      def integer_value(raw)
        return raw if raw.is_a?(Integer)
        return unless raw.is_a?(String)

        Integer(raw, 10)
      rescue ArgumentError
        nil
      end

      # Re-initialize a lost or corrupt counter at a floor no visible sequence
      # exceeds, so recovery never reuses a published sequence. Fails closed
      # when the backend cannot hold the recovered value.
      def recover_counter!(key, observed_raw, slot: nil)
        floor = counter_floor(key, slot)
        COUNTER_RECOVERY_ATTEMPTS.times do
          atomic_delete_if_equal(key, observed_raw) if observed_raw
          atomic_write_if_absent(key, floor)
          observed_raw = @backend.read(key)
          value = integer_value(observed_raw)
          return value if value
        end

        raise BackendWriteError,
              "SolidCache backend could not recover counter #{key.inspect}; " \
              'clear the corrupt entry or repair the cache backend'
      end

      def counter_floor(key, slot)
        return ring_sequence_floor(slot) if slot

        unless counters_initialized?(key)
          seed_sibling_counter(key)
          return 0
        end

        key == epoch_key ? directory_epoch_floor : directory_sequence_floor
      end

      # A fresh store has neither global counter; anything else is evidence of
      # prior state and forces evidence-based recovery instead of a zero reset.
      def counters_initialized?(key)
        sibling = key == epoch_key ? index_sequence_key : epoch_key
        !integer_value(@backend.read(sibling)).nil?
      end

      def seed_sibling_counter(key)
        sibling = key == epoch_key ? index_sequence_key : epoch_key
        atomic_write_if_absent(sibling, 0)
      end

      # Evidence floor for a slot counter. An occupied slot is scanned in full
      # (the corrupt-counter-with-live-records case); an unoccupied slot is
      # probed at ring position 1 only, so claiming a fresh slot stays O(1).
      # Residual: a backend that evicts a slot counter while leaving crash
      # orphans deeper in an unoccupied ring can refuse publishes until the
      # counter advances past them; bounded and self-healing.
      def ring_sequence_floor(slot)
        occupant = parse_membership(@backend.read(index_slot_key(slot)), expected_slot: slot)
        sequences = [payload_sequence(@backend.read(record_ring_key(slot, 1)))]
        if occupant
          (2..@max_requests_per_session).each do |ring_slot|
            sequences << payload_sequence(@backend.read(record_ring_key(slot, ring_slot)))
          end
          sequences << occupant['record_floor']
        end
        [0, *sequences.compact].max
      end

      def directory_epoch_floor
        directory_slots.filter_map { |entry| entry.membership&.fetch('epoch') }.max || 0
      end

      def directory_sequence_floor
        directory_slots.filter_map { |entry| entry.membership&.fetch('sequence') }.max || 0
      end

      def write!(key, value)
        return if @backend.write(key, value, **write_options)

        raise BackendWriteError, "SolidCache backend failed to write #{key.inspect}"
      end

      def publish_current_slot?(key, sequence, counter_key, slot, value)
        return false unless write_newer_slot(key, sequence, value)

        if stale_sequence?(sequence, @max_requests_per_session, counter_key, slot)
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

      def payload_token(raw)
        return unless raw

        payload = JSON.parse(raw)
        payload['token'] if payload.is_a?(Hash)
      rescue JSON::ParserError, TypeError
        nil
      end

      def admit_session(session_id, epoch)
        DIRECTORY_CLAIM_ATTEMPTS.times do
          membership = build_admission(session_id, epoch)
          return unless membership

          if atomic_write_if_absent(active_key(session_id), serialized_membership(membership))
            refresh_activity!(membership)
            return finalize_admission(membership)
          end

          release_directory_slot(membership)
          concurrent = owned_membership(session_id, current_epoch)
          return concurrent if concurrent

          reclaim_active_mapping(session_id)
        end
        nil
      end

      def build_admission(session_id, epoch)
        attributes = {
          'sequence' => increment!(index_sequence_key),
          'epoch' => epoch,
          'session_id' => session_id.to_s,
          'token' => SecureRandom.hex(16)
        }
        claim_directory_slot(attributes, epoch)
      end

      # Conditionally remove an active mapping with no live directory owner or
      # a stale epoch so the session can be admitted again. Exact-value CAS
      # deletes mean a concurrent valid owner is never removed.
      def reclaim_active_mapping(session_id)
        raw = @backend.read(active_key(session_id))
        return unless raw

        membership = parse_membership(raw)
        if membership.nil?
          atomic_delete_if_equal(active_key(session_id), raw)
        elsif !indexed_membership?(membership) || membership['epoch'] != current_epoch
          retire_membership(membership)
        end
        nil
      end

      def finalize_admission(membership)
        epoch_now = current_epoch
        if current_membership?(membership, epoch_now) && !stale_index_sequence?(membership['sequence'])
          return membership
        end

        retire_membership(membership)
        owned_membership(membership['session_id'], epoch_now)
      end

      def claim_directory_slot(attributes, admission_epoch)
        DIRECTORY_CLAIM_ATTEMPTS.times do |attempt|
          epoch = attempt.zero? ? admission_epoch : current_epoch
          slots = directory_slots
          membership = claim_reclaimable_slot(attributes, slots, epoch)
          return membership if membership

          victim = oldest_active_membership(slots.filter_map(&:membership), epoch)
          retire_membership(victim) if victim
        end

        raise DirectoryContentionError,
              "SolidCacheStore could not claim a directory slot after #{DIRECTORY_CLAIM_ATTEMPTS} attempts " \
              "for #{attributes['session_id'].inspect}; retry the record operation or investigate backend contention"
      end

      def claim_reclaimable_slot(attributes, slots, epoch)
        slots.each do |entry|
          occupant = entry.membership
          next if occupant && active_current_membership?(occupant, epoch)

          if occupant
            retire_membership(occupant)
          elsif entry.raw
            atomic_delete_if_equal(index_slot_key(entry.slot), entry.raw)
          end
          membership = attributes.merge(
            'slot' => entry.slot,
            'record_floor' => counter_value(slot_sequence_key(entry.slot), slot: entry.slot)
          )
          return membership if claim_directory_slot?(membership)
        end
        nil
      end

      def oldest_active_membership(memberships, epoch)
        memberships.compact.select { |membership| active_current_membership?(membership, epoch) }
                   .min_by { |membership| membership['sequence'] }
      end

      def claim_directory_slot?(membership)
        key = index_slot_key(membership['slot'])
        written = atomic_write_if_absent(key, serialized_membership(membership))
        written && indexed_membership?(membership)
      end

      def active_memberships
        epoch = current_epoch
        directory_slots.filter_map(&:membership)
                       .select { |membership| active_current_membership?(membership, epoch) }
                       .sort_by { |membership| membership['sequence'] }
      end

      def directory_slots
        @max_sessions.times.map do |slot|
          raw = @backend.read(index_slot_key(slot))
          DirectorySlot.new(slot: slot, raw: raw, membership: parse_membership(raw, expected_slot: slot))
        end
      end

      def owned_membership(session_id, epoch)
        membership = active_membership(session_id)
        membership if membership && membership['epoch'] == epoch && indexed_membership?(membership)
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

        valid_membership_identity?(membership) && valid_membership_epoch?(membership) &&
          valid_membership_position?(membership)
      end

      def valid_membership_identity?(membership)
        membership['sequence'].is_a?(Integer) && membership['sequence'].positive? &&
          membership['session_id'].is_a?(String) && membership['token'].is_a?(String)
      end

      def valid_membership_epoch?(membership)
        membership['epoch'].is_a?(Integer) && membership['epoch'] >= 0
      end

      def valid_membership_position?(membership)
        membership['slot'].is_a?(Integer) && membership['slot'].between?(0, @max_sessions - 1) &&
          membership['record_floor'].is_a?(Integer) && membership['record_floor'] >= 0
      end

      def current_membership?(membership, epoch)
        membership['epoch'] == epoch &&
          stored_membership(membership['session_id']) == membership &&
          indexed_membership?(membership)
      end

      def active_current_membership?(membership, epoch)
        membership['epoch'] == epoch &&
          active_membership(membership['session_id']) == membership &&
          indexed_membership?(membership)
      end

      def retire_membership(membership)
        atomic_delete_if_equal(active_key(membership['session_id']), serialized_membership(membership))
        @backend.delete(activity_key(membership))
        release_directory_slot(membership)
        cleanup_slot_records(membership)
      end

      def refresh_activity!(membership)
        return unless @expires_in

        write!(activity_key(membership), true)
      end

      # Delete only the ring records owned by the retired membership's token,
      # bounded to the window it could have written. A successor's records
      # carry a different token and are never touched.
      def cleanup_slot_records(membership)
        slot = membership['slot']
        upper = counter_value(slot_sequence_key(slot), slot: slot)
        lower = [membership['record_floor'] + 1, upper - @max_requests_per_session + 1, 1].max
        (lower..upper).each do |sequence|
          key = record_key(slot, sequence)
          raw = @backend.read(key)
          next unless raw && payload_token(raw) == membership['token']

          atomic_delete_if_equal(key, raw)
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

      def stale_sequence?(sequence, window_size, counter_key, slot = nil)
        sequence <= counter_value(counter_key, slot: slot) - window_size
      end

      def stale_index_sequence?(sequence)
        stale_sequence?(sequence, @max_sessions, index_sequence_key)
      end

      def current_epoch
        counter_value(epoch_key)
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

      def record_key(slot, sequence)
        ring_slot = ((sequence - 1) % @max_requests_per_session) + 1
        record_ring_key(slot, ring_slot)
      end

      def record_ring_key(slot, ring_slot)
        "#{INDEX_PREFIX}:slot:#{slot}:record:#{ring_slot}"
      end

      def epoch_key
        "#{INDEX_PREFIX}:epoch"
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
