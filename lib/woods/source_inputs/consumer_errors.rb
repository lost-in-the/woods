# frozen_string_literal: true

require 'English'

module Woods
  module SourceInputs
    # Error handlers can return the same nil/empty result as a successful
    # negative match. Keep explicit evidence on the consumer instance instead
    # of guessing from results or intercepting the application's logger.
    module ConsumerErrors
      FLAG = :@woods_source_consumer_failed
      # Schema reads of the consumer that failed on a database that answers:
      # `{ kind: :timeout | :connection | :statement, pool: }` each. A full
      # run refuses them ({schema_failed?}); a database no read can reach is
      # not listed, so such a run still publishes and warns.
      READ_FAILURES = :@woods_schema_read_failures
      # A wait for a pool's connection that ran out.
      TIMEOUT_ERRORS = %w[ConnectionTimeoutError].freeze
      # A connection that could not be made. {TIMEOUT_ERRORS} subclass it, so
      # {#read_failure_kind} asks about them first.
      CONNECTION_ERRORS = %w[ConnectionNotEstablished].freeze
      # A statement the database received and refused.
      STATEMENT_ERRORS = %w[StatementInvalid].freeze
      # Subclasses of {STATEMENT_ERRORS} that mean the database does not exist.
      UNREACHABLE_ERRORS = %w[NoDatabaseError].freeze

      module_function

      def record(consumer)
        consumer.instance_variable_set(FLAG, true)
      end

      # Mark the consumer, and list the failure when +error+ is a schema read
      # that failed on a database that answers.
      #
      # The pool the error carries (Rails 7.1 and later attach the one the
      # read used) wins over +pool+: a handler can rescue reads that went
      # through another pool than the one it names.
      #
      # @param consumer [Object]
      # @param error [Exception, nil]
      # @param pool [Object, nil] the handler's pool, used only when +error+
      #   carries none (Rails before 7.1, or an error raised without one)
      # @return [void]
      def record_read_failure(consumer, error, pool = nil)
        record(consumer)
        kind = read_failure_kind(error)
        return unless kind

        pool = (error.connection_pool if error.respond_to?(:connection_pool)) || pool
        failures = consumer.instance_variable_get(READ_FAILURES) || []
        consumer.instance_variable_set(READ_FAILURES, failures + [{ kind: kind, pool: pool }])
      end

      def reset(consumer)
        consumer.instance_variable_set(FLAG, false)
        consumer.instance_variable_set(READ_FAILURES, nil)
      end

      def failed?(consumer)
        consumer && consumer.instance_variable_get(FLAG) == true
      end

      # Whether a schema read of the consumer failed on a database the run
      # could otherwise read: a refused statement, or a checkout that timed
      # out or a connection that failed on a pool +readable+ vouches for. A
      # failure whose pool is not known (Rails before 7.1 does not attach it,
      # and the handler did not name one) cannot be shown to be such a pool,
      # and does not count.
      #
      # @param consumer [Object, nil]
      # @param readable [#call, nil] pool => whether the run could read it, for
      #   example {Extraction::ServedPools#served?}
      # @return [Boolean]
      def schema_failed?(consumer, readable = nil)
        failures = consumer&.instance_variable_get(READ_FAILURES)
        Array(failures).any? do |failure|
          failure[:kind] == :statement || (!failure[:pool].nil? && readable&.call(failure[:pool]) == true)
        end
      end

      # Called from a rescue clause, so +$ERROR_INFO+ is the error being
      # handled; {#record_read_failure} classifies it, so each of the many
      # handlers need not name the error classes.
      #
      # @param consumer [Object]
      # @param pool [Object, nil] the pool the handler expects the read used,
      #   when the error carries none; see {#record_read_failure}
      # @return [void]
      def log(consumer, *message, pool: nil, &block)
        record_read_failure(consumer, $ERROR_INFO, pool)
        Rails.logger.error(*message, &block)
      end

      # @param error [Exception, nil]
      # @return [Symbol, nil] +:timeout+, +:connection+, +:statement+, or nil
      #   when +error+ is no schema read failure on a database that answers
      def read_failure_kind(error)
        return nil unless error && defined?(::ActiveRecord)
        return nil if active_record_error?(error, UNREACHABLE_ERRORS)
        return :timeout if active_record_error?(error, TIMEOUT_ERRORS)
        return :connection if active_record_error?(error, CONNECTION_ERRORS)

        :statement if active_record_error?(error, STATEMENT_ERRORS)
      end

      # @return [Boolean] whether +error+ is an instance of a named Active Record error
      def active_record_error?(error, names)
        names.any? do |name|
          ::ActiveRecord.const_defined?(name, false) && error.is_a?(::ActiveRecord.const_get(name, false))
        end
      end
    end
  end
end
