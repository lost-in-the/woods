# frozen_string_literal: true

require_relative 'schema_version'
require_relative 'migrations/001_create_units'
require_relative 'migrations/002_create_edges'
require_relative 'migrations/003_create_embeddings'
require_relative 'migrations/004_create_snapshots'
require_relative 'migrations/005_create_snapshot_units'
require_relative 'migrations/006_rename_tables'

module Woods
  module Db
    # Runs schema migrations against a database connection.
    #
    # Tracks applied migrations via {SchemaVersion} and only runs pending ones.
    # Migrations are defined as modules in `db/migrations/` with a VERSION
    # constant and a `.up(connection)` class method.
    #
    # @example
    #   db = SQLite3::Database.new('woods.db')
    #   migrator = Migrator.new(connection: db)
    #   migrator.migrate!  # => [1, 2, 3]
    #
    class Migrator
      MIGRATIONS = [
        Migrations::CreateUnits,
        Migrations::CreateEdges,
        Migrations::CreateEmbeddings,
        Migrations::CreateSnapshots,
        Migrations::CreateSnapshotUnits,
        Migrations::RenameTables
      ].freeze

      attr_reader :schema_version

      # @param connection [Object] Database connection supporting #execute
      def initialize(connection:)
        @connection = connection
        @schema_version = SchemaVersion.new(connection: connection)
        @schema_version.ensure_table!
      end

      # Run all pending migrations.
      #
      # @return [Array<Integer>] Version numbers of newly applied migrations
      def migrate!
        applied = []
        pending_migrations.each do |migration|
          migration.up(@connection)
          @schema_version.record_version(migration::VERSION)
          applied << migration::VERSION
        end
        applied
      end

      private

      # @return [Array<Module>] Pending migration modules
      def pending_migrations
        applied = @schema_version.applied_versions
        MIGRATIONS.reject { |m| applied.include?(m::VERSION) }
      end
    end
  end
end
