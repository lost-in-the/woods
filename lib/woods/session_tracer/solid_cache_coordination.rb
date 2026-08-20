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
            routed_delete(key, :delete_entry)
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
            insert_result = insert_entry(entry_class, key, payload)
            inserted = inserted?(entry_class, insert_result, key, payload)
            @cache.send(:track_writes, 1) if inserted
            inserted
          end
          backend_result!(result, :write_if_absent, name)
        end
      end

      def ensure_present(name, value, **options)
        with_operation(:write, name, options) do |key, merged_options, _event|
          entry = cache_entry(name, value, merged_options, version: "woods-ensure:#{SecureRandom.hex(16)}")
          payload = @cache.send(:serialize_entry, entry, **merged_options)
          result = routed_write(key, :write_entry) do
            entry_class = ::SolidCache::Entry
            insert_result = insert_entry(entry_class, key, payload)
            @cache.send(:track_writes, 1) if inserted?(entry_class, insert_result, key, payload)
            stored = @cache.send(:deserialize_entry, entry_class.read(key), **merged_options)
            stored && !stored.expired?
          end
          backend_result!(result, :ensure_present, name)
        end
      end

      def delete_if_equal(name, expected)
        with_operation(:delete, name, nil) do |key, merged_options, _event|
          result = routed_write(key, :delete_entry) do
            entry_class = ::SolidCache::Entry
            key_hash = entry_class.send(:key_hash_for, key)
            entry_class.transaction do
              raw_key, raw_value = entry_class.lock.where(key_hash: key_hash).pick(:key, :value)
              next false unless raw_key == key

              entry = @cache.send(:deserialize_entry, raw_value, **merged_options)
              next false unless entry && !entry.expired? && entry.value == expected

              entry_class.delete_by_key(key)
              true
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
