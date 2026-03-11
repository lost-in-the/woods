# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Woods
  module Generators
    # Rails generator that creates a migration for Woods tables.
    #
    # Usage:
    #   rails generate woods:install
    #
    # Creates a migration with woods_units, woods_edges, and
    # woods_embeddings tables. Works with PostgreSQL, MySQL, and SQLite.
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a migration for Woods tables (units, edges, embeddings)'

      # @return [void]
      def create_migration_file
        migration_template(
          'create_woods_tables.rb.erb',
          'db/migrate/create_woods_tables.rb'
        )
      end
    end
  end
end
