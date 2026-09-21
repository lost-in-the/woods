# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require 'woods/storage/pgvector'

module Woods
  module Generators
    # Rails generator that adds pgvector support to Woods.
    #
    # Requires the pgvector PostgreSQL extension. Creates the `woods_vectors`
    # table (id, native vector column, JSONB metadata) plus an HNSW index —
    # the schema read and written by Woods::Storage::VectorStore::Pgvector.
    # The migration mirrors the adapter's idempotent ensure_schema! DDL, so
    # it coexists with schema creation at embed time.
    #
    # Usage:
    #   rails generate woods:pgvector
    #   rails generate woods:pgvector --dimensions 768
    #
    class PgvectorGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates the woods_vectors table (pgvector column + HNSW index) used by the Woods vector store'

      class_option :dimensions, type: :numeric, default: 1536,
                                desc: 'Vector dimensions (1-2000; default 1536 for text-embedding-3-small)'

      # @return [void]
      def create_migration_file
        @dimensions = options[:dimensions]
        maximum = Woods::Storage::VectorStore::Pgvector::MAX_HNSW_DIMENSIONS
        unless @dimensions.is_a?(Integer) && @dimensions.between?(1, maximum)
          raise ArgumentError, "dimensions must be a positive Integer no greater than #{maximum} for pgvector HNSW"
        end

        migration_template(
          'add_pgvector_to_woods.rb.erb',
          'db/migrate/add_pgvector_to_woods.rb'
        )
      end
    end
  end
end
