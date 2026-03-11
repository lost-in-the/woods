# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module CodebaseIndex
  module Generators
    # Rails generator that creates a migration for CodebaseIndex tables.
    #
    # Usage:
    #   rails generate codebase_index:install
    #
    # Creates a migration with codebase_units, codebase_edges, and
    # codebase_embeddings tables. Works with PostgreSQL, MySQL, and SQLite.
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a migration for CodebaseIndex tables (units, edges, embeddings)'

      # @return [void]
      def create_migration_file
        migration_template(
          'create_codebase_index_tables.rb.erb',
          'db/migrate/create_codebase_index_tables.rb'
        )
      end
    end
  end
end
