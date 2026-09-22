# frozen_string_literal: true

require 'mcp'

module Woods
  module Console
    # Keeps protocol writes separate from the host application's stdout.
    # The SDK still owns framing, negotiation, notifications and shutdown.
    class StdioTransport < ::MCP::Server::Transports::StdioTransport
      # @param server [::MCP::Server] Console server
      # @param output [IO] Original stdout saved before redirecting Rails output
      def initialize(server, output:)
        super(server)
        @output = output
        @output.set_encoding(Encoding::UTF_8)
      end

      # SDK responses, notifications and server requests share this writer.
      # @param message [String, Hash] Encoded JSON or a JSON-compatible message
      # @return [IO] Flushed protocol output
      def send_response(message)
        @output.puts(message.is_a?(String) ? message : JSON.generate(message))
        @output.flush
      end
    end
  end
end
