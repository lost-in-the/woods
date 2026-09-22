# frozen_string_literal: true

require 'json'
require_relative 'managed_child'

module Woods
  module Watch
    # Validates the private attempt protocol independently of application logs.
    class Lifecycle # rubocop:disable Metrics/ClassLength -- one attempt's ordered protocol state must stay together
      # @param launcher [String] expected launcher token
      # @param attempt [String] expected attempt token
      # @param root [String] selected application root
      def initialize(launcher:, attempt:, root:)
        @launcher = launcher
        @attempt = attempt
        @root = File.realpath(root)
      end

      # @return [String, nil] resolved index directory, only after Rails boot
      attr_reader :index, :child_pid, :terminal, :exit_code, :state, :reason

      # @return [Boolean] Rails has resolved the application/index identity
      def booted?
        !@index.nil?
      end

      # @return [Boolean] guardian explicitly reported the application's exit
      def finished?
        @exited == true
      end

      # @param line [String] bounded JSON event from the private descriptor
      # @return [Hash] validated event
      def accept(line)
        raise ArgumentError, 'oversized Woods lifecycle record' if line.bytesize > ManagedChild::MAX_BYTES

        record = JSON.parse(line)
        validate_envelope!(record)
        event = record.fetch('event')
        raise ArgumentError, 'event after guardian exit' if @exited

        if %w[hello spawned exit spawn_error].include?(event)
          guardian_event(record)
        else
          task_event(record)
        end
        record
      rescue JSON::ParserError, KeyError, TypeError, SystemCallError
        raise ArgumentError, 'invalid Woods lifecycle protocol'
      end

      private

      def validate_envelope!(record)
        return if record.is_a?(Hash) && record['version'] == 1 && record['launcher'] == @launcher &&
                  record['attempt'] == @attempt && record['pid'].is_a?(Integer) && record['pid'].positive?

        raise ArgumentError, 'invalid Woods lifecycle envelope'
      end

      def guardian_event(record)
        case record['event']
        when 'hello'
          raise ArgumentError, 'duplicate guardian hello' if @guardian

          @guardian = record['pid']
        when 'spawned'
          spawned(record)
        when 'exit', 'spawn_error'
          validate_guardian!(record)
          validate_exit!(record)
          @exit_code = record['event'] == 'spawn_error' ? 127 : record['code']
          @exited = true
        end
      end

      def spawned(record)
        validate_guardian!(record)
        raise ArgumentError, 'duplicate child spawn' if @spawned

        pid = record['child_pid']
        raise ArgumentError, 'invalid child PID' unless pid.is_a?(Integer) && pid.positive?
        raise ArgumentError, 'child PID changed' if @child_pid && @child_pid != pid

        @child_pid = pid
        @spawned = true
      end

      def validate_exit!(record)
        return if record['event'] == 'spawn_error' && !@spawned
        return if record['event'] == 'exit' && @spawned && exit_status_valid?(record)

        raise ArgumentError, 'invalid guardian exit'
      end

      def exit_status_valid?(record)
        code, signal = record.values_at('code', 'signal')
        return code.between?(0, 255) if code.is_a?(Integer)

        code.nil? && signal.is_a?(Integer) && signal.positive?
      end

      def validate_guardian!(record)
        raise ArgumentError, 'guardian identity mismatch' unless @guardian == record['pid']
      end

      def task_event(record)
        validate_task_identity!(record)
        event = record['event']
        case event
        when 'task_loaded' then load_task(record)
        when 'identity' then resolve_identity(record)
        when 'backend_ready' then ready_backend
        when 'startup' then startup(record)
        when 'terminal' then finish(record)
        else raise ArgumentError, 'unknown Woods lifecycle event'
        end
      end

      def validate_task_identity!(record)
        raise ArgumentError, 'missing guardian hello' unless @guardian
        raise ArgumentError, 'task event after terminal' if @terminal
        raise ArgumentError, 'task identity mismatch' if @child_pid && @child_pid != record['pid']

        @child_pid = record['pid']
      end

      def load_task(record)
        version = record['woods_version']
        unless !@task && version.is_a?(String) && Gem::Version.correct?(version)
          raise ArgumentError, 'invalid task handshake'
        end

        @task = true
        @state = 'booting'
      end

      def resolve_identity(record)
        root, index = record.values_at('root', 'index')
        unless @task && !@index && root.is_a?(String) && File.realpath(root) == @root &&
               index.is_a?(String) && File.expand_path(index) == index
          raise ArgumentError, 'invalid task root/index identity'
        end

        @index = index
        @state = 'starting'
      end

      def ready_backend
        raise ArgumentError, 'invalid backend ready event' unless booted? && !@backend

        @backend = true
        @state = 'reconciling'
      end

      def startup(record)
        validate_startup!(record)
        reconciled = record['reason'] == 'reconciled' && record['generation'].positive?
        raise ArgumentError, 'inconsistent startup completion' unless (record['state'] == 'ready') == reconciled

        @state = record['state']
        @reason = record['reason']
      end

      def validate_startup!(record)
        return if @backend && %w[ready degraded].include?(record['state']) &&
                  ManagedChild::STARTUP_REASONS.include?(record['reason']) &&
                  record['generation'].is_a?(Integer) && record['generation'] >= 0

        raise ArgumentError, 'invalid startup completion'
      end

      def finish(record)
        unless @task && ManagedChild::TERMINAL_REASONS.include?(record['reason'])
          raise ArgumentError, 'invalid terminal event'
        end

        @terminal = record['reason']
      end
    end
  end
end
