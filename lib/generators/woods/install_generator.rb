# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Woods
  module Generators
    # Rails generator that installs Woods into a Rails application.
    #
    # Usage:
    #   rails generate woods:install
    #
    # Creates:
    #   config/initializers/woods.rb        — annotated configuration file
    #   db/migrate/<ts>_create_woods_tables.rb — migration for Woods tables
    #
    # The migration creates woods_units, woods_edges, and woods_embeddings
    # tables. Works with PostgreSQL, MySQL, and SQLite.
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a Woods initializer and migration for Woods tables'

      # @return [void]
      def create_initializer_file
        template 'woods.rb.tt', 'config/initializers/woods.rb'
      end

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
