# frozen_string_literal: true

require 'rbconfig'
require_relative 'managed_process'

module Woods
  module Watch
    # Owns one foreground launcher. Retry policy belongs to that launcher, never
    # to Puma; a failed launcher must not terminate or restart the web server.
    class PumaChild
      # The launcher gives its extraction child ten seconds to stop. Allow its
      # guardian to finish that cleanup before escalating against the launcher.
      STOP_GRACE = 15

      # @param root [String] application root containing bin/woods-watch
      # @param environment [String] finalized Puma environment
      # @param logger [#log] Puma's log writer
      # @param stop_grace [Numeric] graceful owned-process shutdown seconds
      def initialize(root:, environment:, logger:, stop_grace: STOP_GRACE)
        @root = root
        @environment = environment
        @logger = logger
        @stop_grace = stop_grace
        @stopping = false
      end

      # @return [Integer] owned guardian PID, not proof of index readiness
      def start
        @process = ManagedProcess.new(command: [RbConfig.ruby, File.join(@root, 'bin/woods-watch')],
                                      root: @root, env: child_environment, shutdown_timeout: @stop_grace, events: false)
        @process.start
        @observer = Thread.new { observe }
        @observer.name = 'woods-puma-launcher' if @observer.respond_to?(:name=)
        @process.pid
      end

      # @return [void]
      def stop
        @stopping = true
        # Puma can invoke stopped/restart callbacks from a signal trap.
        # Only request and join here; the observer owns locks and IO cleanup.
        (@observer || Thread.new { @process&.stop }).join
      end

      private

      def child_environment
        { 'APP_ENV' => @environment, 'RACK_ENV' => @environment, 'RAILS_ENV' => @environment }
      end

      def observe
        until @stopping
          unless @process.alive?
            @process.stop
            @logger.log('[woods-watch] Puma launcher stopped unexpectedly; automatic maintenance is inactive. ' \
                        'Fix the launcher configuration and restart Puma, or run bin/woods-watch separately.')
            return
          end
          sleep 0.1
        end
      ensure
        @process.stop
      end
    end
  end
end
