# frozen_string_literal: true

require 'shellwords'

module Woods
  module Watch
    class Installation
      # Restricts automatic edits to explicit, verified startup arrangements.
      class Options
        attr_reader :root, :mode, :operation, :child_command, :manager_command, :procfile

        # @param root [String] application root
        # @param options [Hash] installation choices and injectable probe/environment
        def initialize(root:, **options)
          @root = File.realpath(root)
          @mode = options.fetch(:mode, nil)
          @operation = options.fetch(:operation, 'setup')
          @child_command = argv(options.fetch(:child_command, %w[bin/rails woods:watch]))
          @manager_command = options[:manager_command] && argv(options[:manager_command])
          @procfile = options.fetch(:procfile, 'Procfile.dev')
          @environment = options.fetch(:environment, ENV)
          @probe = options.fetch(:probe) { Probe.new(environment: @environment) }
        end

        # @return [void]
        def validate!
          validate_selection!
          raise Conflict, 'Select a root-level Procfile explicitly' unless Layout::PROCFILE.match?(procfile.to_s)
          return if operation == 'remove'

          raise Conflict, 'Application Gemfile is missing' unless File.file?(File.join(root, 'Gemfile'))

          validate_child!
          validate_idle!
          validate_manager! if mode == 'procfile'
          validate_puma! if mode == 'puma'
          @probe.call(root: root, child_command: child_command,
                      manager_command: mode == 'procfile' ? manager_command : nil, puma: mode == 'puma')
        end

        # @return [Hash] portable selection persisted in the receipt
        def selection
          { 'mode' => mode, 'child_command' => child_command,
            'manager_command' => mode == 'procfile' ? manager_command : nil,
            'procfile' => mode == 'procfile' ? procfile : nil }
        end

        # @return [String] truthful startup handoff, separate from validation evidence
        def handoff
          case mode
          when 'external'
            "Configure one external supervisor to run: #{Shellwords.join(child_command)}; retain raw exit-75 recovery."
          when 'procfile'
            "Start with #{Shellwords.join(manager_command)}. bin/dev was preserved; verify catch-up and an edit."
          else
            'Start with bin/rails server using config/puma.rb; custom -C startup is unsupported. ' \
            'Verify catch-up and an edit; other environments start no watcher.'
          end
        end

        private

        def argv(value)
          items = value.is_a?(String) ? Shellwords.split(value) : value
          unless items.is_a?(Array) && !items.empty? && items.all? { |arg| valid_argument?(arg) }
            raise Conflict, 'Commands must be nonempty argument vectors, not shell scripts'
          end

          items
        rescue ArgumentError => e
          raise Conflict, "Invalid command arguments: #{e.message}"
        end

        def valid_argument?(argument)
          argument.is_a?(String) && !argument.empty? && !argument.include?("\0")
        end

        def validate_selection!
          unless %w[setup update remove].include?(operation)
            raise Conflict, 'Supported operations: setup, update, remove'
          end
          return if operation == 'remove' || %w[procfile puma external].include?(mode)

          raise Conflict, 'Select mode procfile, puma, or external explicitly'
        end

        def validate_child!
          return if child_command.last == 'woods:watch'

          raise Conflict, 'Child command must end with woods:watch so preflight can verify the installed task with -T'
        end

        def validate_idle!
          value = @environment['WOODS_WATCH_IDLE_TIMEOUT']
          return if mode == 'external' || value.to_s.strip.empty?

          raise Conflict, 'Unset WOODS_WATCH_IDLE_TIMEOUT; managed maintenance needs a resident child'
        end

        def validate_manager!
          unless valid_manager?
            raise Conflict, 'Select verified Foreman startup with -f matching the Procfile; ' \
                            'plain Rails bin/dev needs Puma mode'
          end
          document = Woods::AgentConfiguration::Document.new(File.join(root, procfile))
          raise Conflict, "Selected Procfile does not exist: #{procfile}" unless document.content
        end

        def validate_puma!
          return unless File.exist?(File.join(root, 'config/puma/development.rb'))

          raise Conflict, 'Puma selects config/puma/development.rb before config/puma.rb; ' \
                          'use external/Foreman mode for custom Puma configuration'
        end

        def valid_manager?
          args = manager_command
          return false unless args

          args = args.drop(2) if args.first(2) == %w[bundle exec]
          return false unless args.length == 4 && File.basename(args[0]) == 'foreman'

          args[1] == 'start' && %w[-f --procfile].include?(args[2]) && args[3] == procfile
        end
      end
    end
  end
end
