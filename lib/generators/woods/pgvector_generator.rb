# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Woods
  module Generators
    # Rails generator that adds pgvector support to Woods.
    #
    # Requires the pgvector PostgreSQL extension. Adds a native vector column
    # and HNSW index to the woods_embeddings table.
    #
    # Usage:
    #   rails generate woods:pgvector
    #   rails generate woods:pgvector --dimensions 3072
    #
    class PgvectorGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Adds pgvector native vector column and HNSW index to woods_embeddings'

      class_option :dimensions, type: :numeric, default: 1536,
                                desc: 'Vector dimensions (1536 for text-embedding-3-small, 3072 for large)'

      # @return [void]
      def create_migration_file
        @dimensions = options[:dimensions]
        migration_template(
          'add_pgvector_to_woods.rb.erb',
          'db/migrate/add_pgvector_to_woods.rb'
        )
      end
    end
  end
end
