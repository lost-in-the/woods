# frozen_string_literal: true

require 'pathname'
require_relative 'error'

module Woods
  module AgentConfiguration
    # Supported command shapes are built as argv, never as shell snippets.
    class Launcher
      attr_reader :root, :index, :mode, :service, :container_root

      def initialize(root:, index: 'tmp/woods', mode: 'host', service: nil, container_root: nil)
        @root = File.realpath(root)
        @index = Pathname.new(index).cleanpath.to_s
        @mode = mode
        @service = service
        @container_root = container_root
        unless !Pathname.new(@index).absolute? && @index != '..' && !@index.start_with?('../')
          raise Conflict, 'Index must be an explicit path inside the selected application root'
        end
        raise Conflict, 'Application Gemfile is missing' unless File.file?(File.join(@root, 'Gemfile'))
        raise Conflict, 'Supported launch modes: host, compose' unless %w[host compose].include?(mode)

        validate_compose! if mode == 'compose'
      end

      def entry
        argv = prefix + ['bundle', 'exec', 'woods-mcp-start', index_path]
        { 'type' => 'stdio', 'command' => argv.first, 'args' => argv.drop(1), 'env' => environment }
      end

      def probe_command(script)
        prefix(frozen: true) + ['bundle', 'exec', 'ruby', '-e', script, index_path, process_root]
      end

      def environment
        mode == 'host' ? { 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') } : {}
      end

      def probe_environment
        environment.merge('BUNDLE_FROZEN' => 'true')
      end

      def intent
        { 'mode' => mode, 'index' => index, 'service' => service, 'container_root' => container_root }.compact
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
