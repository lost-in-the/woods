# frozen_string_literal: true

module Woods
  module Extraction
    # One catalog read per (connection pool, table, kind) for the length of
    # a run. The pool, not its configuration's labels, names the database:
    # a model's own +establish_connection+ hash is labelled "primary" too.
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
    # the database for them again. {RuntimeCaches} keeps that a live read.
    module SchemaReads
      KINDS = %i[columns indexes foreign_keys primary_keys].freeze

      # One read's result, and the lock that lets concurrent workers that
      # miss the same read wait for one query instead of each running it.
      Entry = Struct.new(:lock, :value, :done)

      class << self
        # @yieldreturn the block's value
        def with
          return yield if @store

          @store = {}.compare_by_identity
          @lock = Mutex.new
          begin
            @cleared = RuntimeCaches.clear
            yield
          ensure
            @store = nil
            @cleared = nil
          end
        end

        # Active Record's schema cache for +connection+ when, inside a run, it
        # can answer for +table+ as a live read would: the connection's pool
        # was emptied when this run started. A table it does not know
        # (ignored, or a name it cannot see) is left to the caller.
        #
        # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
        # @param table [String]
        # @return [Object, nil] the connection's schema cache, or nil
        def runtime_cache(connection, table)
          return unless emptied_this_run?(connection)

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

          entry = @lock.synchronize do
            (store[database_key(connection)] ||= {})[[kind, table.to_s]] ||= Entry.new(Mutex.new)
          end
          entry.lock.synchronize do
            entry.value = connection.public_send(kind, table) unless entry.done
            entry.done = true
            entry.value
          end
        end

        private

        def emptied_this_run?(connection)
          cleared = @cleared
          return false unless @store && cleared && connection.respond_to?(:schema_cache)

          pool = RuntimeCaches.pool_of(connection)
          !pool.nil? && cleared.key?(pool)
        end

        # The pool, compared by identity: two pools never share an answer,
        # whatever their configurations are called.
        def database_key(connection)
          RuntimeCaches.pool_of(connection) || connection
        end
      end

      # Empties Active Record's schema caches when a run starts and says
      # which ones it emptied. Three rules keep {SchemaReads.runtime_cache} a
      # live read:
      #
      # - every pool the connection handler lists is emptied, connected or
      #   not, because a long-lived process (the watch daemon, an application
      #   calling {Woods.extract!}) can hold a schema that a migration has
      #   since changed, and a pool's cache outlives +disconnect!+;
      # - only a pool emptied that way is read through, so a pool created
      #   later, one in a role the handler did not list, or one whose clear
      #   failed is read live;
      # - a database that could have loaded a schema cache dump is neither
      #   emptied nor read through: the dump is a file, not the database, and
      #   the application loaded it on purpose.
      #
      # Emptying takes no connection and only replaces (Rails 7.1 and later)
      # or empties (earlier) the cache's tables, as Rails' own reloader does.
      module RuntimeCaches
        class << self
          # @return [Hash{Object => true}] the pools emptied, by identity
          def clear
            cleared = {}.compare_by_identity
            dumps = {}.compare_by_identity
            each_pool do |pool|
              next if dump_possible?(pool, dumps)

              cleared[pool] = true if empty(pool)
            end
            cleared
          end

          # @return [Object, nil]
          def pool_of(connection)
            connection.respond_to?(:pool) ? connection.pool : nil
          end

          # @return [Object, nil]
          def db_config(pool)
            pool.respond_to?(:db_config) ? pool.db_config : nil
          end

          private

          def each_pool
            return unless defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.respond_to?(:connection_handler)

            pool_list(::ActiveRecord::Base.connection_handler).each do |pool|
              yield pool
            rescue StandardError
              next
            end
          rescue StandardError
            nil
          end

          # Every role's pools on Rails 7.1 and later, where +:all+ also keeps
          # 7.1 from printing a deprecation (or raising, under +:raise+) on
          # each run. Before 7.1 the handler lists only the current role's
          # pools; any other pool is read live.
          def pool_list(handler)
            return handler.connection_pool_list if handler.method(:connection_pool_list).arity.zero?
            return handler.connection_pool_list(:all) if active_record_7_1?

            handler.connection_pool_list
          end

          def active_record_7_1?
            ::ActiveRecord.respond_to?(:version) && ::ActiveRecord.version >= Gem::Version.new('7.1')
          end

          # Rails 7.1 and later keep the cache on the pool config
          # (+schema_reflection+), earlier versions on the pool
          # (+schema_cache+, nil until first use, which is as good as empty).
          def empty(pool)
            if pool.respond_to?(:schema_reflection)
              pool.schema_reflection.clear!
            elsif pool.respond_to?(:schema_cache)
              pool.schema_cache&.clear!
            else
              return
            end
            pool
          end

          # Whether Active Record could have loaded a schema cache dump for
          # the pool's database. Deliberately broad: a configured path, the
          # +SCHEMA_CACHE+ variable or any dump file under the application's
          # +db/+ (or the directory +config.paths["db"]+ names) counts, and
          # so does an application without a root.
          # +memo+ holds each configuration's answer by identity, since two
          # configurations can share labels and differ in +schema_cache_path+,
          # and the directory scan once under +:files+.
          def dump_possible?(pool, memo)
            config = db_config(pool)
            memo.fetch(config) { memo[config] = dump_configured?(config, memo) }
          end

          def dump_configured?(config, memo)
            return true unless ENV['SCHEMA_CACHE'].to_s.empty?
            return true if config.respond_to?(:schema_cache_path) && config.schema_cache_path

            memo.fetch(:files) { memo[:files] = dump_file_present? }
          end

          def dump_file_present?
            root = defined?(::Rails) && ::Rails.respond_to?(:root) ? ::Rails.root : nil
            return true unless root

            dirs = [File.join(root.to_s, 'db'), tasks_db_dir(root)].compact.uniq
            dirs.any? { |dir| Dir.glob(File.join(dir, '**', '*schema_cache*')).any? }
          end

          # Where Active Record's tasks write, and its railtie reads, dumps
          # when the application moved +db/+.
          def tasks_db_dir(root)
            return unless defined?(::ActiveRecord::Tasks::DatabaseTasks)

            dir = ::ActiveRecord::Tasks::DatabaseTasks.db_dir
            dir && File.expand_path(dir.to_s, root.to_s)
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
