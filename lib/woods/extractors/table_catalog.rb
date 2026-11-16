# frozen_string_literal: true

require_relative 'source_origin'

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

      # Worst first: the state a database reports when its pools disagree.
      SCHEMA_STATES = %w[unreachable empty readable].freeze

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
      #   @return [Object, nil] a connection pool on that database, to read the table's schema through
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

          tables = pools.flat_map do |database, pool|
            table_names(pool).map do |name|
              Table.new(name: name, database: database, models: owners.fetch([database, name], []),
                        qualified: qualified, pool: pool)
            end
          end
          new(tables)
        end

        # The database configuration a pool connects to. Rails 6.1+ names the
        # configuration on the pool. Rails 6.0 names the connection
        # specification instead, which is the owning class for a `connects_to`
        # pool, so the configuration is found by its connection settings.
        #
        # @param pool [Object] a connection pool
        # @return [String, nil]
        def database_name(pool)
          return pool.db_config.name.to_s if pool.respond_to?(:db_config)
          return nil unless pool.respond_to?(:spec)

          legacy_configuration_name(pool.spec) || pool.spec.name.to_s
        rescue StandardError
          nil
        end

        # Whether each database the catalog lists tables from could be read.
        # A database is `unreachable` when listing what it holds raises (it
        # does not exist, refuses the connection, or a model has no pool). A
        # database a concrete model reads is also `empty` when it answers but
        # holds nothing beyond the Rails bookkeeping tables. A writable pool
        # no concrete model reads (a connection class over SQL-only tables) is
        # asked only whether it answers: holding no tables is its own choice.
        # One absent table beside others is the model's own
        # `table_exists: false`, not an unreadable schema.
        #
        # @param connection_classes [Array<Class>, nil] Active Record classes;
        #   defaults to `ActiveRecord::Base` (for its pool; it is never a model)
        #   and its descendants
        # @return [Array<Hash>] one `{name:, state:, error:}` per database,
        #   sorted by name; `error` names the failure for the log and is nil
        #   unless the database is unreachable
        def schema_readability(connection_classes: nil)
          classes = connection_classes || runtime_classes
          models = connection_classes || classes.reject { |klass| klass.equal?(ActiveRecord::Base) }
          claims = models.filter_map { |klass| schema_claim(klass) }
          databases = claims.group_by { |claim| claim[:database] }.map do |database, database_claims|
            states = database_claims.map { |claim| claim[:pool] }.uniq.map { |pool| listing_state(pool) }
            state, error = states.min_by { |(candidate, _)| SCHEMA_STATES.index(candidate) }
            { name: database, state: state, error: error }
          end
          modeled = databases.map { |database| database[:name] }
          databases += writable_pools(classes).except(*modeled).map do |database, pool|
            state, error = listing_state(pool)
            { name: database, state: state == 'empty' ? 'readable' : state, error: error }
          end
          databases.sort_by { |database| database[:name].to_s }
        end

        private

        def schema_claim(klass)
          name = klass.name
          return nil if name.nil? || name.split('::').last.start_with?('HABTM_')
          return nil if klass.respond_to?(:abstract_class?) && klass.abstract_class?
          return nil if klass.table_name.nil?
          # The migration bookkeeping and engine models Rails defines exist in
          # an app that has no schema of its own; db:prepare need not give them a table.
          return nil if SourceOrigin.constant_origin(klass) == SourceOrigin::FRAMEWORK

          pool = pool_of(klass)
          return { database: nil, pool: nil } if pool.nil?
          return nil if replica?(pool)

          { database: database_name(pool), pool: pool }
        rescue StandardError
          nil
        end

        # @return [Array(String, String)] the state and, when unreachable, the error
        def listing_state(pool)
          return ['unreachable', 'no connection pool'] if pool.nil?

          names = pool.with_connection(&:data_sources).map(&:to_s) - INTERNAL_TABLES
          [names.empty? ? 'empty' : 'readable', nil]
        rescue StandardError => e
          ['unreachable', "#{e.class}: #{e.message}"]
        end

        def runtime_classes
          return [] unless defined?(ActiveRecord::Base)

          [ActiveRecord::Base, *ActiveRecord::Base.descendants]
        end

        # One pool per database: several classes can hold their own pool on
        # the same configuration (`ActiveRecord::Base` and an abstract class
        # that `connects_to` it).
        #
        # @return [Hash{String, nil => Object}] database name => pool
        def writable_pools(classes)
          classes.each_with_object({}) do |klass, pools|
            pool = pool_of(klass)
            next if pool.nil? || replica?(pool)

            pools[database_name(pool)] ||= pool
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

        def legacy_configuration_name(spec)
          settings = spec.config.transform_keys(&:to_s)
          match = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).find do |candidate|
            candidate.config.transform_keys(&:to_s) == settings
          end
          match&.spec_name&.to_s
        rescue StandardError
          nil
        end

        def table_names(pool)
          names = pool.with_connection(&:tables)
          (names.map(&:to_s) - INTERNAL_TABLES).sort
        rescue StandardError => e
          Rails.logger.warn("[Woods] Could not list tables for a database connection: #{e.message}")
          []
        end

        # @return [Hash{Array(String, String) => Array<String>}] [database, table] => owner names
        def owners_by_table(classes)
          claims = classes.filter_map { |klass| ownership_claim(klass) }
          claims.group_by { |claim| [claim[:database], claim[:table]] }
                .transform_values { |table_claims| ordered_owner_names(table_claims) }
        end

        def ownership_claim(klass)
          name = klass.name
          return nil if name.nil? || name.split('::').last.start_with?('HABTM_')
          return nil if klass.respond_to?(:abstract_class?) && klass.abstract_class?

          pool = pool_of(klass)
          table = klass.table_name
          return nil if pool.nil? || table.nil?

          { database: database_name(pool), table: table.to_s, name: name, root: klass.base_class.equal?(klass) }
        rescue StandardError
          nil
        end

        # Inheritance roots own the table; subclasses only share it.
        def ordered_owner_names(claims)
          roots = claims.select { |claim| claim[:root] }
          (roots.empty? ? claims : roots).map { |claim| claim[:name] }.uniq.sort
        end
      end

      # @param tables [Array<Table>]
      def initialize(tables)
        @tables = tables.sort_by(&:identifier).freeze
        @by_name = @tables.group_by(&:name)
      end

      # @return [Array<Table>] every table, sorted by identifier
      attr_reader :tables

      # The facts a table unit and its consumers read off the catalog: which
      # tables exist (identifiers carry the database name once several pools
      # exist) and which models own each. Two catalogs with equal facts yield
      # equal table, migration, view and consumer units.
      #
      # @return [Hash{String => Array<String>}] table identifier => owning model names
      def ownership_facts
        @tables.to_h { |table| [table.identifier, Array(table.models)] }
      end

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
        return nil if @tables.empty?

        database = self.class.database_name(model.connection_pool)
        named(model.table_name).find { |table| table.database == database }
      rescue StandardError
        nil
      end
    end
  end
end
