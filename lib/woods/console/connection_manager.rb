# frozen_string_literal: true

require 'shellwords'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class ConnectionError < Woods::Error; end

    # Resolves and launches an embedded Console MCP process.
    #
    # The former implementation spoke a private JSON-lines bridge protocol to
    # a scaffold that returned static data. The supported path now forwards the
    # MCP client's stdio directly to the real embedded server by replacing this
    # process with a direct, Docker, or SSH command.
    class ConnectionManager
      DEFAULT_COMMAND = 'bundle exec rake woods:console'

      # @param config [Hash] Process-launch configuration
      # @option config [String] 'mode' direct, docker, or ssh (default: direct)
      # @option config [String] 'command' Embedded server command
      # @option config [String] 'directory' Working directory for direct mode
      # @option config [String] 'container' Container name for docker mode
      # @option config [String] 'host' SSH host for ssh mode
      # @option config [String] 'user' Optional SSH user
      def initialize(config:)
        @config = config
        @mode = config.fetch('mode', 'direct')
        @embedded_command = config.fetch('command', DEFAULT_COMMAND)
      end

      # Return the argv used to launch the embedded MCP server.
      #
      # @return [Array<String>]
      # @raise [ConnectionError] when the mode is invalid or incomplete
      def command
        case @mode
        when 'direct' then embedded_argv
        when 'docker' then docker_command
        when 'ssh' then ssh_command
        else raise ConnectionError, "Unknown connection mode: #{@mode}"
        end
      end

      # Replace the current process with the embedded MCP server.
      #
      # Process replacement gives the MCP client direct ownership of lifecycle:
      # EOF, INT, and TERM reach the real server without an intermediate process
      # that can hang while waiting for a child.
      #
      # @return [void]
      # @raise [ConnectionError] when the process cannot be launched
      def replace_process!
        if @mode == 'direct' && @config['directory']
          Dir.chdir(@config['directory']) { exec(*command) }
        else
          exec(*command)
        end
      rescue SystemCallError, ArgumentError => e
        raise ConnectionError, "Failed to launch embedded Console MCP (#{@mode}): #{e.message}"
      end

      private

      def embedded_argv
        argv = @embedded_command.to_s.shellsplit
        raise ConnectionError, 'Console command must not be empty' if argv.empty?

        argv
      rescue ArgumentError => e
        raise ConnectionError, "Invalid console command: #{e.message}"
      end

      def docker_command
        container = @config['container'] || raise(ConnectionError, 'Docker mode requires container name')
        ['docker', 'exec', '-i', container] + embedded_argv
      end

      def ssh_command
        host = @config['host'] || raise(ConnectionError, 'SSH mode requires host')
        target = @config['user'] ? "#{@config['user']}@#{host}" : host
        ['ssh', target] + embedded_argv
      end
    end
  end
end
