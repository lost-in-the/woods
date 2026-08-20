# frozen_string_literal: true

require_relative 'store'

module Woods
  module MCP
    module Tasks
      # Wiring for the `io.modelcontextprotocol/tasks` extension.
      #
      # The mcp gem does not implement this extension (as of 1.2.0 it still
      # defines neither the `tasks/*` methods nor native task result helpers), so
      # Woods supplies the missing pieces itself:
      #
      # * capability detection, by reading the per-request `_meta` the SDK
      #   passes through untouched, and
      # * the `tasks/get` / `tasks/update` RPCs, plus a stable unsupported
      #   response for `tasks/cancel`, via `define_custom_method`.
      #
      # Both are deliberately thin. When the SDK grows native support this
      # collapses to deleting {install} and pointing the pipeline tools at the
      # SDK's own task handle; {Store} — the durable part, which is the part
      # that actually buys crash resilience — is unaffected either way.
      module Extension
        # Extension identifier, as advertised in capabilities and as looked for
        # in the client's per-request capabilities.
        EXTENSION_ID = 'io.modelcontextprotocol/tasks'

        # Reserved `_meta` key carrying the client's per-request capabilities.
        CLIENT_CAPABILITIES_KEY = 'io.modelcontextprotocol/clientCapabilities'

        # Tasks are an extension to the stateless lifecycle, not a legacy
        # initialize capability. Both the version and explicit extension opt-in
        # must be present on the same request.
        PROTOCOL_VERSION_KEY = 'io.modelcontextprotocol/protocolVersion'
        MODERN_PROTOCOL_VERSION = '2026-07-28'

        class << self
          # Did this request's client declare support for the Tasks extension?
          #
          # The spec is explicit that a server must never hand a task to a
          # client that did not opt in — such a client would treat the handle as
          # the final result and report a run that had not happened. So this
          # answers **false** for anything it cannot positively confirm:
          # a legacy client with no `_meta`, a modern client that declared other
          # extensions, or a malformed envelope.
          #
          # Params arrive deep-symbolized from the transport but are written
          # with string keys in the spec and in hand-built calls, so both forms
          # are read.
          #
          # @param params [Hash, nil] the `tools/call` params
          # @return [Boolean]
          def client_opted_in?(params)
            version = dig_indifferent(params, :_meta, PROTOCOL_VERSION_KEY)
            return false unless version == MODERN_PROTOCOL_VERSION

            extensions = dig_indifferent(params, :_meta, CLIENT_CAPABILITIES_KEY, :extensions)
            return false unless extensions.is_a?(Hash)

            extensions.key?(EXTENSION_ID) || extensions.key?(EXTENSION_ID.to_sym)
          end

          # The `CreateTaskResult` returned in place of a synchronous result.
          #
          # @param task [Store::Task]
          # @return [Hash]
          def create_task_result(task)
            task.to_h.merge(resultType: 'task')
          end

          # Register the `tasks/*` RPCs and advertise the extension.
          #
          # @param server [MCP::Server]
          # @param store [Store]
          # @return [MCP::Server]
          def install(server, store:)
            advertise(server)
            define_get(server, store)
            define_unsupported_cancel(server)
            define_update(server, store)
            server
          end

          private

          def advertise(server)
            capabilities = server.capabilities || {}
            extensions = capabilities[:extensions] || {}
            server.capabilities = capabilities.merge(
              extensions: extensions.merge(EXTENSION_ID => {})
            )
          end

          def define_get(server, store)
            server.define_custom_method(method_name: 'tasks/get') do |params, server_context:|
              require_tasks_capability!(params, server_context)
              task = store.get(task_id_from(params))
              unless task
                raise ::MCP::Server::RequestHandlerError.new(
                  'Unknown or expired taskId.', params, error_type: :invalid_params
                )
              end

              task.to_h.merge(resultType: 'complete')
            end
          end

          def define_unsupported_cancel(server)
            server.define_custom_method(method_name: 'tasks/cancel') do |params, server_context:|
              require_tasks_capability!(params, server_context)
              raise ::MCP::Server::RequestHandlerError.new(
                'Method not found', params,
                error_type: :method_not_found,
                error_code: ::JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND,
                error_data: 'Task cancellation is not supported by Woods.'
              )
            end
          end

          def define_update(server, store)
            server.define_custom_method(method_name: 'tasks/update') do |params, server_context:|
              require_tasks_capability!(params, server_context)
              # No Woods task ever enters `input_required` — nothing in the
              # index pipeline pauses for user input — so there are never
              # outstanding `inputRequests` to satisfy and the spec's guidance
              # ("ignore responses for unknown or already-satisfied keys")
              # makes this an acknowledgement. The method exists because the
              # extension advertises it, and a client that probes it should get
              # an answer rather than "method not found".
              task = store.get(task_id_from(params))
              unless task
                raise ::MCP::Server::RequestHandlerError.new(
                  'Unknown or expired taskId.', params, error_type: :invalid_params
                )
              end

              { resultType: 'complete' }
            end
          end

          def require_tasks_capability!(params, server_context)
            return if server_context&.protocol_version == MODERN_PROTOCOL_VERSION &&
                      client_capabilities_include_tasks?(server_context.client_capabilities)
            return if client_opted_in?(params)

            required = { extensions: { EXTENSION_ID => {} } }
            raise ::MCP::Server::MissingRequiredClientCapabilityError.new(required, params)
          end

          def client_capabilities_include_tasks?(capabilities)
            return false unless capabilities.is_a?(Hash)

            extensions = capabilities[:extensions] || capabilities['extensions']
            return false unless extensions.is_a?(Hash)

            extensions.key?(EXTENSION_ID) || extensions.key?(EXTENSION_ID.to_sym)
          end

          # Custom-method blocks are instance-exec'd without access to module
          # privates, so this is defined on the module itself and reached
          # through the closure over `Extension`.
          def task_id_from(params)
            return nil unless params.is_a?(Hash)

            params[:taskId] || params['taskId']
          end

          # Reads a nested value tolerating symbol/string keys at every level.
          def dig_indifferent(hash, *keys)
            keys.reduce(hash) do |node, key|
              return nil unless node.is_a?(Hash)

              value = node[key]
              value = node[key.to_s] if value.nil?
              value = node[key.to_sym] if value.nil? && key.respond_to?(:to_sym)
              value
            end
          end
        end
      end
    end
  end
end
