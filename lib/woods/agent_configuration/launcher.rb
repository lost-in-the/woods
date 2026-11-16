# frozen_string_literal: true

require 'pathname'
require_relative 'error'
require_relative '../mcp/client_entry'

module Woods
  module AgentConfiguration
    # Supported command shapes are built as argv, never as shell snippets,
    # except the relative form, which is {Woods::MCP::ClientEntry}'s.
    #
    # Two entry forms:
    # - `absolute`: names this machine's application root, Gemfile and index
    #   (and the Compose project directory). Per-machine; user scope always.
    # - `relative`: the checkout-aware entry with no absolute path, for a
    #   project configuration that is committed and shared by every checkout
    #   and worktree. It needs the application inside a git checkout.
    class Launcher
      FORMS = %w[relative absolute].freeze

      attr_reader :root, :index, :mode, :service, :container_root, :form

      # @param settings [Hash] `index:`, `mode:`, `service:`, `container_root:`
      def initialize(root:, form: 'absolute', **settings)
        unknown = settings.keys - %i[index mode service container_root]
        raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?
        raise Conflict, 'Supported entry forms: --entry-form relative or absolute' unless FORMS.include?(form)

        @form = form
        @root = File.realpath(root)
        @index = Pathname.new(settings.fetch(:index, 'tmp/woods')).cleanpath.to_s
        @mode = settings.fetch(:mode, 'host')
        @service = settings[:service]
        @container_root = settings[:container_root]
        validate!
        @location = locate if form == 'relative'
      end

      def entry
        if form == 'relative'
          return MCP::ClientEntry.checkout(service: (service if mode == 'compose'), application: @location.application,
                                           output: @location.output)
        end

        argv = prefix + ['bundle', 'exec', 'woods-mcp-start', index_path]
        { 'type' => 'stdio', 'command' => argv.first, 'args' => argv.drop(1), 'env' => environment }
      end

      # The relative form also asks the probe to resolve the checkout from the
      # application root and to load the `--checkout --await-index` support.
      def probe_command(script)
        prefix(frozen: true) + ['bundle', 'exec', 'ruby', '-e', script, index_path, process_root] +
          (form == 'relative' ? ['relative'] : [])
      end

      def environment
        mode == 'host' ? { 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') } : {}
      end

      def probe_environment
        environment.merge('BUNDLE_FROZEN' => 'true')
      end

      def intent
        { 'mode' => mode, 'index' => index, 'service' => service, 'container_root' => container_root,
          'entry_form' => form }.compact
      end

      private

      def process_root
        mode == 'host' ? root : container_root
      end

      def index_path
        File.join(process_root, index)
      end

      def prefix(frozen: false)
        return [] if mode == 'host'

        ['docker', 'compose', '--project-directory', root, 'exec', '-T', '-w', container_root] +
          (frozen ? ['-e', 'BUNDLE_FROZEN=true'] : []) + [service]
      end

      def validate!
        unless !Pathname.new(@index).absolute? && @index != '..' && !@index.start_with?('../')
          raise Conflict, 'Index must be an explicit path inside the selected application root'
        end
        raise Conflict, 'Application Gemfile is missing' unless File.file?(File.join(@root, 'Gemfile'))
        raise Conflict, 'Supported launch modes: host, compose' unless %w[host compose].include?(mode)

        validate_compose! if mode == 'compose'
      end

      def locate
        MCP::ClientEntry.locate(root, index: index)
      rescue ArgumentError
        raise Conflict, "#{root} is not inside a git checkout, so `woods-mcp-start --checkout` cannot find it; " \
                        'use --entry-form absolute'
      end

      def validate_compose!
        unless service.is_a?(String) && service.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
          raise Conflict, 'Compose mode requires an explicit service name'
        end
        return if container_root.is_a?(String) && Pathname.new(container_root).absolute?

        raise Conflict, 'Compose mode requires the absolute application path visible inside the container'
      end
    end
  end
end
