# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'
require 'woods/version'

module Woods
  module Generators
    # Rails generator that installs Woods into a Rails application.
    #
    # Usage:
    #   rails generate woods:install
    #   rails generate woods:install --legacy-migration
    #
    # Creates:
    #   config/initializers/woods.rb — annotated configuration file
    #
    # With `--legacy-migration` it also writes
    # db/migrate/<ts>_create_woods_tables.rb, the compatibility migration for
    # the `woods_units`/`woods_edges`/`woods_embeddings` application tables.
    # Shipped v2 paths do not use those tables, so a default install writes
    # no migration; the option exists only for an older/custom integration
    # that deliberately uses them (#618).
    #
    # The default path needs railties only. Active Record is loaded lazily,
    # and only for the legacy migration, so `rails generate woods:install`
    # works in an application that does not ship Active Record.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a Woods initializer (and, with --legacy-migration, the legacy compatibility migration)'

      class_option :legacy_migration, type: :boolean, default: false,
                                      desc: 'Also write the legacy woods_units/woods_edges/woods_embeddings ' \
                                            'migration (older/custom integrations only)'

      # Rails generators otherwise print Thor errors and return a successful status.
      # @return [Boolean] whether a refused installation fails the CLI command
      def self.exit_on_failure?
        true
      end

      # Timestamp a legacy migration the way Active Record's own generators
      # do (honouring `timestamped_migrations`). Only reached under
      # `--legacy-migration`, after Active Record has been loaded.
      #
      # @param dirname [String] the migration directory
      # @return [String]
      def self.next_migration_number(dirname)
        ActiveRecord::Migration.next_migration_number(current_migration_number(dirname) + 1)
      end

      # Refuse `--legacy-migration` before writing anything when Active
      # Record cannot be loaded, so a failed run leaves no half-install.
      #
      # @return [void]
      def verify_legacy_migration_support
        return unless options[:legacy_migration]

        require 'active_record'
      rescue LoadError => e
        raise Thor::Error, "--legacy-migration needs Active Record, which could not be loaded (#{e.message}). " \
                           'Run without the option for the initializer-only install.'
      end

      # @return [void]
      def create_initializer_file
        template 'woods.rb.tt', 'config/initializers/woods.rb'
      end

      # @return [void]
      def create_migration_file
        return unless options[:legacy_migration]

        migration_template(
          'create_woods_tables.rb.erb',
          'db/migrate/create_woods_tables.rb'
        )
      end
    end
  end
end
