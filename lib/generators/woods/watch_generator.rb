# frozen_string_literal: true

require 'rails/generators'
require 'woods/watch/installation'

module Woods
  module Generators
    # Reversible opt-in startup integration; never rewrites an application's bin/dev.
    class WatchGenerator < Rails::Generators::Base
      desc 'Install, update, or remove owned Woods watcher startup configuration'

      class_option :mode, type: :string, desc: 'Explicit startup mode: procfile, puma, or external'
      class_option :operation, type: :string, default: 'setup', desc: 'setup, update, remove, or recover'
      class_option :procfile, type: :string, default: 'Procfile.dev', desc: 'Existing root-level Foreman Procfile'
      class_option :manager_command, type: :string,
                                     desc: 'Normal Foreman startup argv, e.g. foreman start -f Procfile.dev'
      class_option :child_command, type: :string, default: 'bin/rails woods:watch',
                                   desc: 'Application task command, parsed as argv (no shell evaluation)'

      # Rails generators otherwise print Thor errors and return a successful status.
      # @return [Boolean] whether a refused installation fails the CLI command
      def self.exit_on_failure?
        true
      end

      # @return [void]
      def configure_watcher
        operation = behavior == :revoke ? 'remove' : options[:operation]
        installation = build_installation(operation)
        if operation == 'recover'
          say installation.recover(pretend: options[:pretend])
          return
        end
        plan = installation.plan
        say JSON.pretty_generate(plan.summary)
        return if options[:pretend]

        say installation.apply(plan)
        say installation.handoff unless operation == 'remove'
      rescue Woods::Watch::Installation::Conflict => e
        raise Thor::Error, e.message
      end

      private

      def build_installation(operation)
        Woods::Watch::Installation.new(root: destination_root, mode: options[:mode], operation: operation,
                                       procfile: options[:procfile], manager_command: options[:manager_command],
                                       child_command: options[:child_command])
      end
    end
  end
end
