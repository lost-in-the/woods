# frozen_string_literal: true

module Woods
  module Extractors
    # The tables the running application can reach, and the models that own
    # them, read from the connections themselves.
    #
    # Every extractor that names a table (table units, migrations, views,
    # models, declared external consumers) resolves it here, so they agree on
    # the table unit's identifier and on whether a model owns the table today.
    # Nothing is derived from `db/schema.rb` or from a class name guessed out
    # of the table name.
    #
    # @example
    #   catalog = TableCatalog.from_runtime
    #   catalog.named('ledger_entries').map(&:identifier) # => ["table:ledger_entries"]
    #   catalog.named('ledger_entries').first.model       # => nil (no model owns it)
    #
    class TableCatalog
      # Rails bookkeeping tables. They are never units and never edge targets.
      INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata].freeze

      IDENTIFIER_PREFIX = 'table:'

      # One live table.
      #
      # @!attribute name
      #   @return [String] table name as the connection reports it
      # @!attribute database
      #   @return [String, nil] database configuration name
      # @!attribute models
      #   @return [Array<String>] owning model names, inheritance roots first
      # @!attribute qualified
      #   @return [Boolean] whether the identifier carries the database name
      # @!attribute pool
      #   @return [Object, nil] connection pool to read the table's schema through
      Table = Struct.new(:name, :database, :models, :qualified, :pool, keyword_init: true) do
        # @return [String] the table unit's identifier
        def identifier
          qualified ? "#{IDENTIFIER_PREFIX}#{database}.#{name}" : "#{IDENTIFIER_PREFIX}#{name}"
        end

        # @return [String, nil] the model that owns this table, if any
        def model
          Array(models).first
        end
      end

      class << self
        # Read the catalog from the running application.
        #
        # @param connection_classes [Array<Class>, nil] Active Record classes to
        #   take connection pools and ownership from. Defaults to
        #   `ActiveRecord::Base` and its descendants.
        # @return [TableCatalog]
        def from_runtime(connection_classes: nil)
          classes = connection_classes || runtime_classes
          pools = writable_pools(classes)
          owners = owners_by_table(classes)
          qualified = pools.size > 1

          tables = pools.flat_map do |pool, database|
            table_names(pool).map do |name|
              Table.new(name: name, database: database, models: owners.fetch([pool, name], []),
                        qualified: qualified, pool: pool)
            end
          end
          new(tables)
        end

        private

        def runtime_classes
          return [] unless defined?(ActiveRecord::Base)

          [ActiveRecord::Base, *ActiveRecord::Base.descendants]
        end

        # @return [Hash{Object => String, nil}] pool => database name, identity-keyed
        def writable_pools(classes)
          classes.each_with_object({}.compare_by_identity) do |klass, pools|
            pool = pool_of(klass)
            next if pool.nil? || pools.key?(pool) || replica?(pool)

            pools[pool] = database_name(pool)
          end
        end

        def pool_of(klass)
          klass.connection_pool
        rescue StandardError
          nil
        end

        def replica?(pool)
          pool.respond_to?(:db_config) && pool.db_config.respond_to?(:replica?) && pool.db_config.replica?
        end

        # Rails 6.1+ names the configuration on the pool; Rails 6.0 names the
        # connection specification instead.
        def database_name(pool)
          return pool.db_config.name.to_s if pool.respond_to?(:db_config)

          pool.respond_to?(:spec) ? pool.spec.name.to_s : nil
        rescue StandardError
          nil
        end

        def table_names(pool)
          names = pool.with_connection(&:tables)
          names.map(&:to_s) - INTERNAL_TABLES
        rescue StandardError => e
          Rails.logger.warn("[Woods] Could not list tables for a database connection: #{e.message}")
          []
        end

        # @return [Hash{Array(Object, String) => Array<String>}] identity-keyed on the pool
        def owners_by_table(classes)
          claims = classes.each_with_object({}.compare_by_identity) do |klass, by_pool|
            claim = ownership_claim(klass)
            next unless claim

            ((by_pool[claim[:pool]] ||= {})[claim[:table]] ||= []) << claim
          end
          claims.each_with_object(PoolTableIndex.new) do |(pool, by_table), index|
            by_table.each { |table, table_claims| index.store(pool, table, ordered_owner_names(table_claims)) }
          end
        end

        def ownership_claim(klass)
          name = klass.name
          return nil if name.nil? || name.split('::').last.start_with?('HABTM_')
          return nil if klass.respond_to?(:abstract_class?) && klass.abstract_class?

          pool = pool_of(klass)
          table = klass.table_name
          return nil if pool.nil? || table.nil?

          { pool: pool, table: table.to_s, name: name, root: klass.base_class.equal?(klass) }
        rescue StandardError
          nil
        end

        # Inheritance roots own the table; subclasses only share it.
        def ordered_owner_names(claims)
          roots = claims.select { |claim| claim[:root] }
          (roots.empty? ? claims : roots).map { |claim| claim[:name] }.uniq.sort
        end
      end

      # Lookup keyed on pool identity and table name. Pools are compared by
      # identity because test doubles and real pools alike define no value
      # equality worth trusting.
      class PoolTableIndex
        def initialize
          @by_pool = {}.compare_by_identity
        end

        # @return [void]
        def store(pool, table, value)
          (@by_pool[pool] ||= {})[table] = value
        end

        # @return [Object] the stored value, or +default+
        def fetch(key, default)
          pool, table = key
          @by_pool.fetch(pool, {}).fetch(table, default)
        end
      end

      # @param tables [Array<Table>]
      def initialize(tables)
        @tables = tables.sort_by(&:identifier).freeze
        @by_name = @tables.group_by(&:name)
      end

      # @return [Array<Table>] every table, sorted by identifier
      attr_reader :tables

      # Tables with this name, one per database that has it.
      #
      # @param name [String]
      # @return [Array<Table>] sorted by identifier
      def named(name)
        @by_name.fetch(name.to_s, [])
      end

      # The table a model class reads, on that class's own connection.
      #
      # @param model [Class] an Active Record class
      # @return [Table, nil] nil when the name is not a live table (a view, or no table yet)
      def for_model(model)
        pool = model.connection_pool
        named(model.table_name).find { |table| table.pool.equal?(pool) }
      rescue StandardError
        nil
      end
    end
  end
end
