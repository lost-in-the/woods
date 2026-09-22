# frozen_string_literal: true

require 'json'

module Woods
  module Watch
    # Private, bounded lifecycle reporting for a task owned by woods-watch.
    # Raw rake tasks do not open descriptors or alter their lifecycle.
    class ManagedChild
      ENV_KEYS = %w[WOODS_WATCH_EVENT_FD WOODS_WATCH_LAUNCHER_TOKEN WOODS_WATCH_ATTEMPT_TOKEN].freeze
      TOKEN = /\A[A-Za-z0-9_-]{1,128}\z/
      MAX_BYTES = 4096
      FIELDS = {
        task_loaded: %i[woods_version], identity: %i[root index], backend_ready: [],
        startup: %i[state generation reason], terminal: %i[reason]
      }.freeze
      STARTUP_REASONS = %w[reconciled startup_failed pending_work restart_required no_index catch_up_disabled].freeze
      TERMINAL_REASONS = %w[restart_required already_running stopped idle unsupported_environment].freeze

      # @param env [#[]] child process environment
      # @return [ManagedChild, nil] nil for an ordinary unmanaged task
      def self.from_env(env: ENV)
        values = ENV_KEYS.map { |key| env[key] }
        return if values.all?(&:nil?)

        descriptor, launcher, attempt = values
        validate_environment!(descriptor, [launcher, attempt])

        unless env['WOODS_WATCH_IDLE_TIMEOUT'].to_s.empty?
          raise ArgumentError, 'WOODS_WATCH_IDLE_TIMEOUT must be unset for managed watching'
        end

        new(IO.for_fd(descriptor.to_i, 'w'), launcher: launcher, attempt: attempt)
      end

      def self.validate_environment!(descriptor, tokens)
        valid_tokens = tokens.all? { |token| token.is_a?(String) && token.match?(TOKEN) }
        valid_fd = descriptor.is_a?(String) && descriptor.match?(/\A\d+\z/) && descriptor.to_i >= 3
        return if valid_tokens && valid_fd

        raise ArgumentError, 'invalid Woods managed-child environment'
      end
      private_class_method :validate_environment!

      # @param io [IO] private event descriptor owned by this reporter
      # @param launcher [String] supervisor identity token
      # @param attempt [String] current child attempt identity token
      def initialize(io, launcher:, attempt:)
        @io = io
        @io.binmode
        @io.sync = true
        @io.close_on_exec = true
        @launcher = launcher
        @attempt = attempt
        @mutex = Mutex.new
      end

      # @param event [Symbol] an allowlisted lifecycle boundary
      # @param fields [Hash] bounded protocol data, never application exceptions
      # @return [void]
      def call(event, **fields)
        validate!(event, fields)
        message = JSON.generate(version: 1, launcher: @launcher, attempt: @attempt,
                                event: event.to_s, pid: Process.pid, **fields) << "\n"
        raise ArgumentError, 'Woods lifecycle message exceeds size limit' if message.bytesize > MAX_BYTES

        @mutex.synchronize { @io.write(message) }
      end

      # @return [void]
      def close
        @mutex.synchronize { @io.close unless @io.closed? }
      end

      private

      def validate!(event, fields)
        expected = FIELDS[event]
        raise ArgumentError, 'invalid Woods lifecycle event fields' unless expected && fields.keys.sort == expected.sort

        validate_payload!(event, fields)
      end

      def validate_payload!(event, fields)
        case event
        when :startup then validate_startup!(fields)
        when :terminal
          raise ArgumentError, 'invalid Woods terminal reason' unless TERMINAL_REASONS.include?(fields[:reason])
        when :identity
          validate_identity!(fields)
        when :task_loaded
          raise ArgumentError, 'invalid Woods version' unless fields[:woods_version].is_a?(String)
        end
      end

      def validate_identity!(fields)
        return if %i[root index].all? do |key|
          fields[key].is_a?(String) && fields[key] == File.expand_path(fields[key])
        end

        raise ArgumentError, 'Woods lifecycle identity must contain absolute paths'
      end

      def validate_startup!(fields)
        return if %w[ready degraded].include?(fields[:state]) &&
                  fields[:generation].is_a?(Integer) && fields[:generation] >= 0 &&
                  STARTUP_REASONS.include?(fields[:reason])

        raise ArgumentError, 'invalid Woods startup state or reason'
      end
    end
  end
end
