# frozen_string_literal: true

require_relative 'connection_manager'

module Woods
  module Console
    class UnsupportedBridgeError < Woods::Error; end

    # Compatibility constant for the removed JSON-lines bridge scaffold.
    #
    # The scaffold returned empty arrays and zero counts for live queries. It is
    # intentionally impossible to construct so no caller can mistake fabricated
    # data for application state. Use the embedded stdio or HTTP server instead.
    class StubBridge
      MESSAGE = 'The JSON-lines Console bridge is not supported; use the embedded stdio or HTTP server.'

      # @raise [UnsupportedBridgeError] always
      def initialize(**)
        raise UnsupportedBridgeError, MESSAGE
      end
    end
  end
end
