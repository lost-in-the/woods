# frozen_string_literal: true

require_relative '../build_identity'

module Woods
  module MCP
    # Explains a failed read as a writer/reader build gap when it is one.
    #
    # An index written by another Woods build (another version string, or the
    # same string at another git revision) can fail this reader's payload
    # guards, which then read as corruption (`typed unit identity mismatch`,
    # "An Index artifact is unavailable or malformed"). Backward-compatible
    # reading is not offered; the honest answer is which build wrote the index
    # and what to run. When the pinned index's writer differs from this build,
    # a `corrupt_artifact` or internal-error tool result is replaced by that
    # message, with error code `index_build_mismatch` and the original text
    # kept in `_meta.read_error`. Results from an index this build wrote, and
    # every other error, pass through unchanged.
    #
    # Installed before {IndexReaderPinning}, so it runs inside the pin and
    # the routed worktree: the manifest it compares is the one the call read.
    module BuildGap
      # Tool error codes a build gap can explain.
      EXPLAINED_CODES = %w[corrupt_artifact internal_error].freeze

      class << self
        # @param server [MCP::Server]
        # @param router [WorktreeRouting::Router]
        # @param build [BuildIdentity]
        # @return [MCP::Server]
        def install(server, router:, build: BuildIdentity.current)
          server.singleton_class.prepend(Dispatch)
          server.instance_variable_set(:@woods_build_gap_router, router)
          server.instance_variable_set(:@woods_build_gap_build, build)
          server
        end

        # @param reader [#manifest, nil]
        # @param build [BuildIdentity]
        # @return [BuildComparison, nil] only a known mismatch
        def mismatch(reader, build)
          manifest = reader.respond_to?(:manifest) ? reader.manifest : nil
          comparison = BuildIdentity.compare(manifest, reader: build)
          comparison if comparison.mismatch?
        rescue StandardError
          nil
        end

        # @param comparison [BuildComparison]
        # @param tool [String]
        # @param read_error [String, nil]
        # @return [Hash] a tool error result
        def response(comparison, tool:, read_error:)
          meta = { error_code: :index_build_mismatch, tool: tool, build: comparison.to_h }
          meta[:read_error] = read_error if read_error
          text = comparison.message
          ::MCP::Tool::Response.new([{ type: 'text', text: text }], error: true, structured_content: { text: text },
                                                                    meta: meta).to_h
        end
      end

      # Prepended on the server's singleton class.
      module Dispatch
        private

        def call_tool(request, **kwargs)
          result = super
          return result unless explainable?(result)

          explain(request, read_error: result.dig(:content, 0, :text)) || result
        rescue ::MCP::Server::RequestHandlerError => e
          raise unless e.error_type == :internal_error

          explain(request, read_error: e.original_error&.message) || raise
        end

        def explainable?(result)
          return false unless result.is_a?(Hash) && result[:isError]

          EXPLAINED_CODES.include?(result.dig(:_meta, :error_code).to_s)
        end

        def explain(request, read_error:)
          router = @woods_build_gap_router
          comparison = BuildGap.mismatch(router&.current_reader, @woods_build_gap_build)
          return unless comparison

          BuildGap.response(comparison, tool: request[:name], read_error: read_error)
        end
      end
    end
  end
end
