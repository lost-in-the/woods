# frozen_string_literal: true

require 'json'
require 'mcp'

module Woods
  module MCP
    # The SDK stdio transport with a frame guard.
    #
    # `MCP::Server::Transports::StdioTransport` tags stdin UTF-8 and calls
    # `String#strip` on every frame before parsing it, so one frame carrying a
    # byte that is not valid UTF-8 raises `Encoding::CompatibilityError` out
    # of {#open} and ends the process; a frame whose JSON escapes decode to
    # invalid UTF-8 (an unpaired surrogate such as `"\udc00"`) survives the
    # strip and raises `EncodingError` when the SDK symbolizes its keys. Both
    # escape the SDK's own rescue (mcp 1.2.0 through 1.6.1), so the packaged
    # Index and Console servers exited with status 1 on a single malformed
    # frame while the HTTP transport answered `invalid_params` for the same
    # bytes.
    #
    # This subclass validates each frame as it is read, before the SDK strips
    # or parses it. A frame that is not valid UTF-8, or that decodes to
    # invalid UTF-8, is answered with the JSON-RPC parse error (-32700) and
    # skipped; the loop then reads the next frame. A frame that merely fails
    # to parse is passed through untouched, so the SDK answers it exactly as
    # before. No frame is ever rewritten: a client that sends `caf\xE9` gets
    # an error for that frame, not a result for `caf�`.
    #
    # Cost: one extra `JSON.parse` of each frame for validation. Frames are
    # tool calls of a few kilobytes, so this is microseconds against the
    # per-call transport overhead.
    #
    # The guard attaches to the SDK's private `read_line(io)` hook, which
    # every release in the supported range defines. The check at load time
    # makes a release that drops the hook fail loudly instead of leaving the
    # servers unguarded.
    class StdioTransport < ::MCP::Server::Transports::StdioTransport
      # JSON-RPC 2.0 "Parse error".
      PARSE_ERROR_CODE = -32_700

      unless superclass.private_method_defined?(:read_line)
        raise LoadError,
              "mcp #{::MCP::VERSION} does not define StdioTransport#read_line; " \
              'the Woods stdio frame guard cannot attach to this release'
      end

      private

      # Reads frames until one is acceptable or stdin is exhausted. A frame the
      # guard rejects is answered here and never reaches the SDK.
      #
      # @param io [IO] the SDK passes `$stdin`
      # @return [String, nil] the next acceptable frame, or nil at EOF
      def read_line(io)
        loop do
          line = super
          return line if line.nil?

          reason = frame_rejection(line)
          return line unless reason

          reject_frame(reason)
        end
      end

      # Why a frame must not reach the SDK, or nil when it may.
      #
      # @param line [String] one newline-delimited frame
      # @return [String, nil]
      def frame_rejection(line)
        return 'frame is not valid UTF-8' unless line.valid_encoding?

        JSON.parse(line, symbolize_names: true)
        nil
      rescue JSON::ParserError
        nil
      rescue EncodingError
        'frame decodes to invalid UTF-8 (an unpaired surrogate escape)'
      end

      # @param reason [String]
      # @return [void]
      def reject_frame(reason)
        warn "[woods stdio] rejected frame (#{PARSE_ERROR_CODE}): #{reason}"
        send_response(JSON.generate(jsonrpc: '2.0', id: nil,
                                    error: { code: PARSE_ERROR_CODE, message: "Parse error: #{reason}" }))
      end
    end
  end
end
