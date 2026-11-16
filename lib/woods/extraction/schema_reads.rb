# frozen_string_literal: true

module Woods
  module Extraction
    # One catalog read per (database, table, kind) for the length of a run.
    #
    # The model extractor and the database table extractor each read the
    # same tables' indexes, foreign keys and primary keys, and the model
    # extractor read a model's foreign keys twice. On SQLite every
    # +foreign_keys+ and +columns+ call also re-reads +sqlite_master+, so the
    # cost grows with the table count squared. Live only inside {.with};
    # outside a run every read goes straight to the connection, as before.
    #
    # Results are the adapter's own objects and are shared: callers read
    # them and never mutate them.
    #
    # Active Record's own schema cache can also stand in for a live read
    # ({.runtime_cache}): the model extractor fills it with every model's
    # columns and primary key, and the table extractor would otherwise ask
    # the database for them again. Two rules keep that a live read:
    # {.with} empties the cache when a run starts, because a long-lived
    # process (the watch daemon) can hold a schema that a migration has since
    # changed; and a database that could have loaded a schema cache dump is
    # never read through it, because the dump is a file, not the database.
    module SchemaReads
      KINDS = %i[columns indexes foreign_keys primary_keys].freeze

      class << self
        # @yieldreturn the block's value
        def with
          return yield if @store

          @store = {}
          @lock = Mutex.new
          @dump_possible = {}
          begin
            clear_runtime_caches
            yield
          ensure
            @store = nil
            @dump_possible = nil
          end
        end

        # Active Record's schema cache for +connection+ when, inside a run, it
        # can answer for +table+ as a live read would. A table it does not know
        # (ignored, or a name it cannot see) is left to the caller.
        #
        # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
        # @param table [String]
        # @return [Object, nil] the connection's schema cache, or nil
        def runtime_cache(connection, table)
          return unless @store && connection.respond_to?(:schema_cache)
          return if dump_possible?(pool_of(connection))

          cache = connection.schema_cache
          cache if cache.respond_to?(:data_source_exists?) && cache.data_source_exists?(table)
        rescue StandardError
          nil
        end

        # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
        # @param kind [Symbol] one of {KINDS}
        # @param table [String]
        # @return [Object] what +connection.public_send(kind, table)+ returns
        def read(connection, kind, table)
          store = @store
          return connection.public_send(kind, table) unless store

          key = [database_key(connection), kind, table.to_s]
          hit = @lock.synchronize { store.fetch(key, nil) }
          return hit if hit

          value = connection.public_send(kind, table)
          @lock.synchronize { store[key] = value }
          value
        end

        private

        def database_key(connection)
          config = db_config(pool_of(connection))
          config ? [config.env_name, config.name] : connection.object_id
        end

        def pool_of(connection)
          connection.respond_to?(:pool) ? connection.pool : nil
        end

        def db_config(pool)
          pool.respond_to?(:db_config) ? pool.db_config : nil
        end

        # Empty the schema cache of every connected pool that {.runtime_cache}
        # may read, so this run's answers are this run's reads.
        def clear_runtime_caches
          return unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.respond_to?(:connection_handler)

          ::ActiveRecord::Base.connection_handler.connection_pool_list.each do |pool|
            next unless pool.connected? && !dump_possible?(pool)

            pool.with_connection { |connection| connection.schema_cache.clear! }
          end
        rescue StandardError
          nil
        end

        # Whether Active Record could have loaded a schema cache dump for the
        # pool's database. Deliberately broad: a configured path, the
        # +SCHEMA_CACHE+ variable or any dump file under +db/+ counts, and so
        # does an application without a root.
        def dump_possible?(pool)
          config = db_config(pool)
          key = config ? [config.env_name, config.name] : :unknown
          return @dump_possible[key] if @dump_possible&.key?(key)

          possible = dump_configured?(config)
          @dump_possible[key] = possible if @dump_possible
          possible
        end

        def dump_configured?(config)
          return true unless ENV['SCHEMA_CACHE'].to_s.empty?
          return true if config.respond_to?(:schema_cache_path) && config.schema_cache_path

          dump_file_present?
        end

        def dump_file_present?
          root = defined?(::Rails) && ::Rails.respond_to?(:root) ? ::Rails.root : nil
          return true unless root

          Dir.glob(root.join('db', '**', '*schema_cache*').to_s).any?
        end
      end
    end
  end
end
