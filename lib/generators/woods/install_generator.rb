# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'
require 'json'
require 'woods/version'
require_relative 'mcp_configuration'

module Woods
  module Generators
    # Rails generator that installs Woods into a Rails application.
    #
    # Usage:
    #   rails generate woods:install
    #   rails generate woods:install --legacy-migration
    #   rails generate woods:install --mcp-config [--mcp-service web]
    #
    # Creates:
    #   config/initializers/woods.rb — annotated configuration file
    #
    # It prints the Index Server entry for an MCP client's `.mcp.json`, and
    # with `--mcp-config` adds it to `.mcp.json` at the application root.
    # The entry names no absolute path and no `cwd`
    # (`woods-mcp-start --checkout --await-index`), so one committed file
    # serves every checkout and worktree on every machine. An existing
    # `woods` entry, a file that is not a JSON object, and a file that
    # `woods-agent-config` manages are never changed.
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
      class_option :mcp_config, type: :boolean, default: false,
                                desc: 'Add the Woods Index Server to .mcp.json (otherwise the entry is only printed)'
      class_option :mcp_service, type: :string,
                                 desc: 'Launch the Index Server in this running Docker Compose service'

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

      # Refuse a service name before writing anything: it is placed in the
      # shell command the container entry runs.
      #
      # @return [void]
      def verify_mcp_service
        service = options[:mcp_service]
        return if service.nil? || service.match?(McpConfiguration::SERVICE_NAME)

        raise Thor::Error, "--mcp-service must be a Docker Compose service name, got #{service.inspect}"
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
      def configure_mcp_client
        return if behavior == :revoke

        entry = mcp_entry
        unless options[:mcp_config]
          say 'Add the Woods Index Server to your MCP client (.mcp.json at the application root), ' \
              'or rerun with --mcp-config to add it:'
          say mcp_snippet(entry)
          return
        end

        write_mcp_config(entry)
      end

      # @return [void]
      def create_migration_file
        return unless options[:legacy_migration]

        migration_template(
          'create_woods_tables.rb.erb',
          'db/migrate/create_woods_tables.rb'
        )
      end

      private

      def mcp_entry
        service = options[:mcp_service]
        Woods::MCP::ClientEntry.for_root(destination_root, service: service, index: configured_index)
      rescue ArgumentError
        say_status :note, 'the application is not inside a git checkout yet; woods-mcp-start --checkout needs one',
                   :yellow
        McpConfiguration.entry(service: service)
      end

      # The index directory relative to the application root: Woods'
      # configured `output_dir` when this run loaded it (a Rails application
      # boots its initializers before generating), else `tmp/woods`. An
      # output_dir outside the checkout cannot be reached by `--checkout`,
      # which only serves an index inside the checkout it runs in.
      def configured_index
        return 'tmp/woods' unless Woods.respond_to?(:configuration)

        root = resolved(File.expand_path(destination_root))
        given = File.expand_path(Woods.configuration.output_dir.to_s, root)
        configured = resolved(given)
        checkout = Woods::MCP::ServedIdentity.checkout_root(root)
        if checkout && !configured.start_with?("#{checkout}/")
          say_status :note, "output_dir #{given} is outside the checkout, where woods-mcp-start --checkout " \
                            'cannot serve it; the entry serves tmp/woods', :yellow
          return 'tmp/woods'
        end

        Pathname.new(configured).relative_path_from(Pathname.new(root)).to_s
      end

      # +path+ with symlinks resolved, as {Woods::MCP::ServedIdentity.checkout_root}
      # resolves the checkout: through its nearest existing ancestor while the
      # directory itself has not been created yet.
      def resolved(path)
        missing = []
        until File.exist?(path)
          missing.unshift(File.basename(path))
          path = File.dirname(path)
        end
        File.join(File.realpath(path), *missing)
      end

      def mcp_snippet(entry)
        McpConfiguration.snippet(entry)
      end

      def write_mcp_config(entry)
        path = File.join(destination_root, '.mcp.json')
        reason = McpConfiguration.skip_reason(destination_root, path, entry)
        return create_file('.mcp.json', "#{mcp_snippet(entry)}\n") if reason == :absent
        return say_status(:identical, '.mcp.json', :blue) if reason == :identical
        return skip_mcp_config(reason, entry) if reason

        say_status :merge, '.mcp.json', :green
        File.write(path, McpConfiguration.merged(path, entry)) unless options[:pretend]
      end

      def skip_mcp_config(reason, entry)
        say_status :skip, ".mcp.json (#{reason})", :yellow
        say 'Add this entry yourself if you want it:'
        say mcp_snippet(entry)
      end
    end
  end
end
