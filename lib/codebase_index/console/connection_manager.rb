# frozen_string_literal: true

require 'json'
require 'open3'

# @see CodebaseIndex
module CodebaseIndex
  class Error < StandardError; end unless defined?(CodebaseIndex::Error)

  module Console
    class ConnectionError < CodebaseIndex::Error; end

    # Manages the bridge process connection via Docker exec, direct spawn, or SSH.
    #
    # Spawns and manages the bridge process, sends JSON-lines requests,
    # receives responses. Implements heartbeat (30s) and reconnect with
    # exponential backoff (max 5 retries).
    #
    # @example
    #   manager = ConnectionManager.new(config: {
    #     'mode' => 'direct',
    #     'command' => 'bundle exec rails runner bridge.rb'
    #   })
    #   manager.connect!
    #   response = manager.send_request({ 'id' => 'r1', 'tool' => 'status', 'params' => {} })
    #   manager.disconnect!
    #
    class ConnectionManager
      MAX_RETRIES = 5
      HEARTBEAT_INTERVAL = 30

      # @param config [Hash] Connection configuration
      # @option config [String] 'mode' Connection mode: 'docker', 'direct', or 'ssh'
      # @option config [String] 'command' Command to run the bridge
      # @option config [String] 'container' Docker container name (docker mode)
      # @option config [String] 'directory' Working directory (direct mode)
      # @option config [String] 'host' SSH host (ssh mode)
      # @option config [String] 'user' SSH user (ssh mode)
      def initialize(config:)
        @config = config
        @mode = config['mode'] || 'direct'
        @command = config['command'] || 'bundle exec rails runner lib/codebase_index/console/bridge.rb'
        @stdin = nil
        @stdout = nil
        @wait_thread = nil
        @retries = 0
        @last_heartbeat = nil
      end

      # Spawn the bridge process.
      #
      # @return [void]
      # @raise [ConnectionError] if the process cannot be started
      def connect!
        cmd = build_command
        @stdin, @stdout, @wait_thread = Open3.popen2(cmd)
        @last_heartbeat = Time.now
        @retries = 0
      rescue StandardError => e
        raise ConnectionError, "Failed to connect (#{@mode}): #{e.message}"
      end

      # Terminate the bridge process.
      #
      # @return [void]
      def disconnect!
        @stdin&.close
        @stdout&.close
        @wait_thread&.value
        @stdin = nil
        @stdout = nil
        @wait_thread = nil
      end

      # Send a request to the bridge and read the response.
      #
      # @param request [Hash] JSON-serializable request hash
      # @return [Hash] Parsed response hash
      # @raise [ConnectionError] if communication fails after retries
      def send_request(request)
        ensure_connected!
        @stdin.puts(JSON.generate(request))
        @stdin.flush
        line = @stdout.gets
        raise ConnectionError, 'Bridge process closed unexpectedly' unless line

        @last_heartbeat = Time.now
        JSON.parse(line)
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET => e
        reconnect_or_raise!(e)
        retry
      end

      # Check if the bridge process is alive.
      #
      # @return [Boolean]
      def alive?
        return false unless @wait_thread

        @wait_thread.alive?
      end

      # Check if a heartbeat is needed (30s since last communication).
      #
      # @return [Boolean]
      def heartbeat_needed?
        return false unless @last_heartbeat

        (Time.now - @last_heartbeat) >= HEARTBEAT_INTERVAL
      end

      private

      # Build the shell command based on connection mode.
      #
      # @return [String]
      def build_command
        case @mode
        when 'docker' then build_docker_command
        when 'ssh'    then build_ssh_command
        when 'direct' then build_direct_command
        else raise ConnectionError, "Unknown connection mode: #{@mode}"
        end
      end

      def build_docker_command
        container = @config['container'] || raise(ConnectionError, 'Docker mode requires container name')
        "docker exec -i #{container} #{@command}"
      end

      def build_ssh_command
        host = @config['host'] || raise(ConnectionError, 'SSH mode requires host')
        user = @config['user']
        target = user ? "#{user}@#{host}" : host
        "ssh #{target} #{@command}"
      end

      def build_direct_command
        dir = @config['directory']
        dir ? "cd #{dir} && #{@command}" : @command
      end

      # Ensure the connection is active.
      def ensure_connected!
        return if alive?

        connect!
      end

      # Attempt reconnection with exponential backoff.
      #
      # @param error [StandardError] The original error
      # @raise [ConnectionError] if max retries exceeded
      def reconnect_or_raise!(error)
        @retries += 1
        if @retries > MAX_RETRIES
          raise ConnectionError,
                "Connection failed after #{MAX_RETRIES} retries: #{error.message}"
        end

        sleep((2**(@retries - 1)) * 0.1)
        disconnect!
        connect!
      end
    end
  end
end
