# frozen_string_literal: true

require 'json'
require 'mcp'
require 'time'
require_relative 'served_identity'

module Woods
  module MCP
    # A server started before its index exists (`woods-mcp-start
    # --await-index`, `WOODS_MCP_AWAIT_INDEX=1`).
    #
    # Without it a missing index is a failed launch: the server exits before
    # `initialize`, so the agent has no tools and nothing that says why. With
    # it the server completes the handshake and registers the tools it always
    # does. `woods_status` reports what it is waiting for ({#status}); every
    # other tool answers a non-error, retryable `building` result, shaped as
    # the hydration `warming` result is; a resource read is refused with
    # `index_building`.
    #
    # The first readable generation ends the wait: the next call goes through
    # to the reader, whose freshness check adopts it as it adopts any newly
    # published generation. The wait is a latch, so damage to a later
    # generation is reported as damage, never as `building`.
    class IndexWait
      ENV_NAME = 'WOODS_MCP_AWAIT_INDEX'

      # Written by an external launcher that started the first extraction.
      BOOTSTRAP_FILE = '.bootstrap.json'

      # The bootstrap file is untrusted: bytes read at most, the fields
      # reported, and the characters kept of each.
      MAX_BOOTSTRAP_BYTES = 4096
      BOOTSTRAP_FIELDS = %w[started_at command state].freeze
      MAX_BOOTSTRAP_FIELD_CHARS = 256

      # `retry_after_seconds` of a `building` answer. A first extraction takes
      # seconds to minutes, so a retry sooner than this learns nothing.
      RETRY_AFTER_SECONDS = 5

      # The one tool that answers while waiting.
      STATUS_TOOL = 'woods_status'

      # @param env [Hash]
      # @return [Boolean]
      def self.requested?(env = ENV)
        ServedIdentity.env_flag?(ENV_NAME, env)
      end

      # @return [String] ISO 8601 time the server started waiting
      attr_reader :since

      # @param index_dir [String, Pathname] the directory an index is awaited in
      # @param reader [#manifest_present?] the server's launch reader
      def initialize(index_dir:, reader:)
        @index_dir = index_dir.to_s
        @reader = reader
        @since = Time.now.utc.iso8601
        @ready = false
      end

      # Whether a published index is readable now. True once it has been.
      #
      # @return [Boolean]
      def ready?
        @ready ||= @reader.manifest_present?
      end

      # The `index` section of `woods_status` while waiting.
      #
      # @return [Hash]
      def status
        {
          state: 'awaiting_index',
          diagnostic: "No Woods index is published in #{@index_dir} yet: it is being built or has not been " \
                      'started. This server serves the first one on the next call, with no restart.',
          watching: @index_dir,
          awaiting_since: @since,
          bootstrap: bootstrap,
          counts: {}
        }
      end

      # The result of any tool but `woods_status` while waiting.
      #
      # @param tool [String]
      # @return [Hash] a serialized tool result
      def building_response(tool)
        message = "Not answered yet: no Woods index is published in #{@index_dir} yet. This is not an empty " \
                  'result and nothing failed. The server serves the first index on the next call, with no ' \
                  'restart. Call woods_status to see what it is waiting for, then retry this call.'
        data = { status: 'building', retryable: true, retry_after_seconds: RETRY_AFTER_SECONDS, tool: tool,
                 index: status }
        ::MCP::Tool::Response.new(
          [{ type: 'text', text: message }],
          structured_content: { text: message, data: data },
          meta: { index: 'building', retryable: true, retry_after_seconds: RETRY_AFTER_SECONDS }
        ).to_h
      end

      # What the launcher-written bootstrap file says, reduced to the fields
      # this server reports, or nil when there is none.
      #
      # @return [Hash, nil]
      def bootstrap
        path = File.join(@index_dir, BOOTSTRAP_FILE)
        return unless File.file?(path)

        bytes = File.open(path, 'rb') { |file| file.read(MAX_BOOTSTRAP_BYTES + 1) }
        return { readable: false, reason: 'malformed' } if bytes.nil?
        return { readable: false, reason: 'too_large' } if bytes.bytesize > MAX_BOOTSTRAP_BYTES

        data = JSON.parse(bytes.force_encoding(Encoding::UTF_8).scrub)
        return { readable: false, reason: 'malformed' } unless data.is_a?(Hash)

        BOOTSTRAP_FIELDS.each_with_object({ readable: true }) do |field, fields|
          value = data[field]
          fields[field.to_sym] = value.dup.force_encoding(Encoding::UTF_8).scrub[0, MAX_BOOTSTRAP_FIELD_CHARS] if
            value.is_a?(String)
        end
      rescue JSON::ParserError, SystemCallError, IOError
        { readable: false, reason: 'malformed' }
      end

      # Prepended onto a built server's singleton class, outermost, so a call
      # made while waiting takes no generation pin and waits for no warm-up.
      module Dispatch
        private

        def call_tool(request, **)
          wait = @woods_index_wait
          name = request[:name]
          return super if wait.nil? || name == STATUS_TOOL || !tools.key?(name) || wait.ready?

          wait.building_response(name)
        end

        def read_resource_contents(request, **)
          wait = @woods_index_wait
          return super if wait.nil? || wait.ready?

          raise ::MCP::Server::RequestHandlerError.new(
            'No Woods index is published yet; call woods_status and retry.', request,
            error_type: :internal_error, error_code: ::JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            error_data: { uri: request[:uri], error_code: 'index_building', retryable: true }
          )
        end
      end
    end
  end
end
