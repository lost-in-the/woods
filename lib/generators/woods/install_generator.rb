# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/migration'
require 'json'
require 'woods/version'
require 'woods/mcp/served_identity'
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
        output = output_below_checkout
        if output && options[:mcp_service]
          say_status :note, 'the container launch serves tmp/woods at the checkout root inside the container; ' \
                            "set WOODS_OUTPUT=#{output} in the #{options[:mcp_service]} service", :yellow
        end
        McpConfiguration.entry(service: options[:mcp_service], output: output)
      end

      def mcp_snippet(entry)
        McpConfiguration.snippet(entry)
      end

      # `--checkout` serves `tmp/woods` at the checkout root; an application
      # below that root names its own, relative to the checkout.
      def output_below_checkout
        checkout = Woods::MCP::ServedIdentity.checkout_root(destination_root)
        return unless checkout

        below = Pathname.new(File.realpath(destination_root)).relative_path_from(Pathname.new(checkout)).to_s
        below == '.' ? nil : File.join(below, 'tmp', 'woods')
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
