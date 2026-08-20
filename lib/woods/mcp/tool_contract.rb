# frozen_string_literal: true

require 'json'
require 'mcp'

module Woods
  module MCP
    # Applies the shared wire contract to every Index MCP tool after conditional
    # registration has finished.
    module ToolContract
      TASK_RESULT_TOOLS = %w[pipeline_embed pipeline_extract].freeze

      INTEGER_BOUNDS = {
        'budget' => [1, 200_000],
        'depth' => [0, 20],
        'limit' => [1, 1_000],
        'min_size' => [1, 100_000],
        'offset' => [0, 1_000_000],
        'score' => [1, 5]
      }.freeze

      OUTPUT_SCHEMA = {
        type: 'object',
        properties: {
          text: { type: 'string' },
          data: {
            type: %w[object array string number boolean null],
            description: 'Parsed JSON payload when the selected renderer emits JSON.'
          }
        },
        required: ['text'],
        additionalProperties: false
      }.freeze

      class << self
        def apply!(server)
          server.tools.each do |name, tool|
            tool.input_schema(close_input_schema(name, tool.input_schema_value.to_h))
            tool.output_schema(OUTPUT_SCHEMA) unless TASK_RESULT_TOOLS.include?(name)
          end
          server.configuration.validate_tool_call_results = true
          server.singleton_class.prepend(Dispatch)
          server
        end

        def artifact_error?(error)
          current = error
          while current
            return true if current.is_a?(JSON::ParserError) || current.is_a?(EncodingError) ||
                           current.is_a?(SystemCallError) || current.is_a?(IOError)

            nested = current.respond_to?(:original_error) ? current.original_error : nil
            nested ||= current.cause
            break if nested.equal?(current)

            current = nested
          end
          false
        end

        private

        def close_input_schema(name, source)
          schema = JSON.parse(JSON.generate(source), symbolize_names: true)
          schema.delete(:$schema)
          schema[:type] = 'object'
          schema[:properties] ||= {}
          schema[:additionalProperties] = false
          add_retrieve_limit!(name, schema[:properties])
          bound_properties!(schema)
          schema
        end

        def add_retrieve_limit!(name, properties)
          return unless name == 'codebase_retrieve'

          properties[:limit] = {
            type: 'integer',
            description: 'Unsupported result-count alias. Use budget instead.'
          }
        end

        def bound_properties!(schema)
          required = Array(schema[:required]).map(&:to_s)
          schema[:properties].each do |name, property|
            case property[:type]
            when 'integer'
              minimum, maximum = INTEGER_BOUNDS.fetch(name.to_s)
              property[:minimum] = minimum
              property[:maximum] = maximum
            when 'string'
              property[:minLength] = 1 if required.include?(name.to_s)
              property[:maxLength] = 10_000
            when 'array'
              property[:maxItems] = 1_000
              property[:items][:maxLength] ||= 10_000 if property.dig(:items, :type) == 'string'
            end
          end
        end
      end

      # The SDK validates schemas, but its generic errors do not carry the
      # stable metadata agents need and a non-object argument reaches required
      # argument inspection before schema validation. Validate at the Index MCP
      # boundary, then delegate valid calls to the SDK unchanged.
      module Dispatch
        def call_tool(request, **kwargs)
          tool = tools[request[:name]]
          return super unless tool

          arguments = request.key?(:arguments) ? request[:arguments] : {}
          return contract_error(request[:name], 'Arguments must be an object.') unless arguments.is_a?(Hash)

          missing = tool.input_schema_value.missing_required_arguments(arguments)
          unless missing.empty?
            return contract_error(
              request[:name],
              "Missing required arguments: #{missing.join(', ')}",
              code: :missing_required_arguments,
              arguments: missing
            )
          end

          begin
            tool.input_schema_value.validate_arguments(arguments)
          rescue ::MCP::Tool::InputSchema::ValidationError => e
            return contract_error(request[:name], e.message)
          end

          super
        rescue ::MCP::Server::RequestHandlerError => e
          raise unless ToolContract.artifact_error?(e)

          contract_error(
            request[:name],
            'An Index artifact is unavailable or malformed.',
            code: :corrupt_artifact
          )
        end

        private

        def contract_error(tool, message, code: :invalid_arguments, **meta)
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: message }],
            error: true,
            structured_content: { text: message },
            meta: { error_code: code, tool: tool }.merge(meta)
          ).to_h
        end
      end
    end
  end
end
