# frozen_string_literal: true

module Woods
  module Observability
    # Lightweight instrumentation wrapper that delegates to ActiveSupport::Notifications
    # when available, and falls back to a simple yield otherwise.
    #
    # @example
    #   Instrumentation.instrument('woods.extraction', unit: 'User') do
    #     extract_unit(user_model)
    #   end
    #
    module Instrumentation
      module_function

      # Instrument a block of code with an event name and payload.
      #
      # Delegates to ActiveSupport::Notifications.instrument when available.
      # Otherwise, yields the block directly.
      #
      # @param event [String] Event name (e.g., 'woods.extraction')
      # @param payload [Hash] Additional data to include with the event
      # @yield [payload] The block to instrument
      # @return [Object] The return value of the block
      def instrument(event, payload = {}, &block)
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(event, payload, &block)
        elsif block
          yield payload
        end
      end
    end
  end
end
