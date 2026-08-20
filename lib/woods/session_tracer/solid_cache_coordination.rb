# frozen_string_literal: true

require 'active_support/cache'
require 'securerandom'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module SessionTracer
    # Uncached, per-key routed coordination operations for Solid Cache 1.0.
    class SolidCacheCoordination # rubocop:disable Metrics/ClassLength
      FAILURE = Object.new.freeze

      class BackendError < Woods::Error; end

      def initialize(cache)
        @cache = cache
      end

      def read(name, options = nil)
        with_operation(:read, name, options) do |key, merged_options, event|
          raw = routed_read(key, :read_entry)
          entry = @cache.send(:deserialize_entry, raw, **merged_options)
          if entry&.expired?
            delete_expired_entry(key, raw)
            entry = nil
          end
          event[:hit] = !entry.nil? if event
          entry&.value
        end
      rescue ActiveSupport::Cache::DeserializationError
        nil
      end

      def write(name, value, **options)
        with_operation(:write, name, options) do |key, merged_options, _event|
          entry = cache_entry(name, value, merged_options)
          payload = @cache.send(:serialize_entry, entry, **merged_options)
          result = @cache.send(:entry_write, key, payload)
          backend_result!(result, :write, name, nil_is_failure: true)
        end
      end

      def delete(name, options = nil)
        with_operation(:delete, name, options) do |key, _merged_options, _event|
          routed_delete(key, :delete_entry).positive?
        end
      end

      def increment(name, amount = 1, options = nil)
        with_operation(:increment, name, options, amount: amount) do |key, merged_options, _event|
          payload = @cache.send(:entry_lock_and_write, key) do |raw|
            entry = @cache.send(:adjusted_entry, raw, amount, merged_options)
            @cache.send(:serialize_entry, entry, **merged_options)
          end
          backend_result!(payload, :increment, name, nil_is_failure: true)
          @cache.send(:deserialize_entry, payload, **merged_options).value
        end
      end

      def write_if_absent(name, value, **options)
        with_operation(:write, name, options) do |key, merged_options, _event|
          entry = cache_entry(name, value, merged_options, version: "woods-cas:#{SecureRandom.hex(16)}")
          payload = @cache.send(:serialize_entry, entry, **merged_options)
          result = routed_write(key, :write_entry) do
            entry_class = ::SolidCache::Entry
            inserted = attempt_insert?(entry_class, key, payload)
            if !inserted && clear_expired_entry?(entry_class, key, merged_options)
              inserted = attempt_insert?(entry_class, key, payload)
            end
            @cache.send(:track_writes, 1) if inserted
            inserted
          end
          backend_result!(result, :write_if_absent, name)
        end
      end

      def delete_if_equal(name, expected)
        with_operation(:delete, name, nil) do |key, merged_options, _event|
          result = routed_write(key, :delete_entry) do
            locked_compare_and_delete(key) do |raw_value|
              entry = @cache.send(:deserialize_entry, raw_value, **merged_options)
              entry && !entry.expired? && entry.value == expected
            end
          end
          backend_result!(result, :delete_if_equal, name)
        end
      end

      private

      def with_operation(operation, name, options, event_options = nil)
        merged_options = @cache.send(:merged_options, options)
        key = @cache.send(:normalize_key, name, merged_options)
        instrument_options = event_options || merged_options

        @cache.send(:bypass_local_cache) do
          @cache.send(:instrument, operation, key, instrument_options) do |event|
            yield key, merged_options, event
          end
        end
      rescue NoMethodError => e
        raise BackendError,
              "Solid Cache private API unavailable for #{operation} #{name.inspect} (#{e.message}); " \
              'this Solid Cache version is not supported by Woods session tracing'
      end

      # Row-locked compare-and-delete on the raw stored payload. The block
      # decides against the exact bytes read under lock, so a concurrent
      # replacement can never be deleted by mistake.
      def locked_compare_and_delete(key)
        entry_class = ::SolidCache::Entry
        key_hash = entry_class.send(:key_hash_for, key)
        entry_class.transaction do
          raw_key, raw_value = entry_class.lock.where(key_hash: key_hash).pick(:key, :value)
          next false unless raw_key == key
          next false unless yield(raw_value)

          entry_class.delete_by_key(key)
          true
        end
      end

      # Conditionally remove an expired entry observed by a read: only the
      # exact expired payload is deleted, never a fresh replacement.
      def delete_expired_entry(key, observed_raw)
        routed_write(key, :delete_entry) do
          locked_compare_and_delete(key) { |raw_value| raw_value == observed_raw }
        end
      end

      def attempt_insert?(entry_class, key, payload)
        inserted?(entry_class, insert_entry(entry_class, key, payload), key, payload)
      end

      # Treat a physically-present but logically-expired row as absent for
      # conditional writes by conditionally removing the exact expired payload.
      def clear_expired_entry?(entry_class, key, merged_options)
        raw = entry_class.read(key)
        return false unless raw

        entry = @cache.send(:deserialize_entry, raw, **merged_options)
        return false unless entry&.expired?

        locked_compare_and_delete(key) { |raw_value| raw_value == raw }
      rescue ActiveSupport::Cache::DeserializationError
        false
      end

      def cache_entry(name, value, options, version: @cache.send(:normalize_version, name, options))
        ActiveSupport::Cache::Entry.new(value, **options, version: version)
      end

      def insert_entry(entry_class, key, payload)
        attributes = entry_class.send(:add_key_hash_and_byte_size, [{ key: key, value: payload }])
        entry_class.insert_all(attributes, unique_by: entry_class.send(:upsert_unique_by))
      end

      def inserted?(entry_class, result, key, payload)
        affected_rows = result.affected_rows if result.respond_to?(:affected_rows)
        return affected_rows.positive? unless affected_rows.nil?
        return result.rows.any? if entry_class.connection.supports_insert_returning?

        entry_class.read(key) == payload
      end

      def routed_read(key, failsafe)
        result = @cache.send(:reading_key, key, failsafe: failsafe, failsafe_returning: FAILURE) do
          ::SolidCache::Entry.read(key)
        end
        backend_result!(result, :read, key)
      end

      def routed_write(key, failsafe, &block)
        @cache.send(:writing_key, key, failsafe: failsafe, failsafe_returning: FAILURE, &block)
      end

      def routed_delete(key, failsafe)
        result = routed_write(key, failsafe) { ::SolidCache::Entry.delete_by_key(key) }
        backend_result!(result, :delete, key)
      end

      def backend_result!(result, operation, key, nil_is_failure: false)
        failed = result.equal?(FAILURE) || (nil_is_failure && result.nil?)
        return result unless failed

        raise BackendError,
              "Solid Cache routed #{operation} failed for #{key.inspect}; inspect the cache backend error handler"
      end
    end
  end
end
