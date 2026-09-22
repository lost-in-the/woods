# frozen_string_literal: true

module Woods
  module Watch
    # Publication and retirement of one launcher's diagnostic records.
    module SupervisorReporting
      private

      def publish(state, reason, **details)
        return unless state

        reason ||= 'pending'
        changed = @state != state || @reason != reason
        @state = state
        @reason = reason
        @details = details
        @logger.puts("[woods-watch] #{state}: #{reason || 'pending'} (attempt #{@attempts})") if changed
        heartbeat(force: true)
      end

      def heartbeat(force: false)
        return unless @status && heartbeat_due?(force)

        @status.write(state: @state, reason: @reason, attempt: @attempt,
                      child_pid: @process&.alive? ? @protocol.child_pid : nil, **(@details || {}))
        @heartbeat_at = monotonic
      rescue SystemCallError, ArgumentError => e
        @logger.puts("[woods-watch] cannot write supervision status (#{e.class})")
        @heartbeat_at = monotonic
      end

      def heartbeat_due?(force)
        force || !@heartbeat_at || monotonic - @heartbeat_at >= 5
      end

      def retire_status
        @status&.write(state: 'stopped', reason: 'attempt_finished', attempt: @attempt, child_pid: nil)
      rescue SystemCallError, ArgumentError => e
        @logger.puts("[woods-watch] cannot retire supervision status (#{e.class})")
      ensure
        @status = nil
        @heartbeat_at = nil
      end
    end
  end
end
