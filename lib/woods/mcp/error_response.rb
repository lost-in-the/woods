# frozen_string_literal: true

require 'mcp'

module Woods
  module MCP
    # MCP 0.9 supports error responses but has no metadata keyword. Keep the
    # existing Woods error contract without changing the SDK's global class.
    class ErrorResponse < ::MCP::Tool::Response
      attr_reader :meta

      def initialize(content, meta:)
        @meta = meta
        super(content, error: true)
      end

      def to_h
        super.merge(_meta: meta)
      end
    end
  end
end
