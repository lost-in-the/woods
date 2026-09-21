# frozen_string_literal: true

module Woods
  module SourceInputs
    # Error handlers can return the same nil/empty result as a successful
    # negative match. Keep explicit evidence on the consumer instance instead
    # of guessing from results or intercepting the application's logger.
    module ConsumerErrors
      FLAG = :@woods_source_consumer_failed

      module_function

      def record(consumer)
        consumer.instance_variable_set(FLAG, true)
      end

      def reset(consumer)
        consumer.instance_variable_set(FLAG, false)
      end

      def failed?(consumer)
        consumer && consumer.instance_variable_get(FLAG) == true
      end

      def log(consumer, ...)
        record(consumer)
        Rails.logger.error(...)
      end
    end
  end
end
