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
            tool.input_schema(close_input_schema(tool.input_schema_value.to_h, name))
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

        def close_input_schema(source, tool_name)
          schema = JSON.parse(JSON.generate(source), symbolize_names: true)
          schema.delete(:$schema)
          schema[:type] = 'object'
          schema[:properties] ||= {}
          schema[:additionalProperties] = false
          bound_properties!(schema, tool_name)
          schema
        end

        def bound_properties!(schema, tool_name)
          required = Array(schema[:required]).map(&:to_s)
          schema[:properties].each do |name, property|
            Array(property[:anyOf]).each { |branch| bound_property!(name, branch, required, tool_name) }
            bound_property!(name, property, required, tool_name)
          end
        end

        def bound_property!(name, property, required, tool_name)
          case property[:type]
          when 'integer'
            minimum, maximum = integer_bounds(name, tool_name)
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

        # Every integer argument on the tool surface must declare its own
        # inclusive range in {INTEGER_BOUNDS}. Fail-closed at Server.build is
        # deliberate — an unbounded integer reaches the handlers — but the
        # failure has to name the table and the property that needs the entry,
        # not surface as a bare KeyError far from its cause.
        def integer_bounds(name, tool_name)
          INTEGER_BOUNDS.fetch(name.to_s) do
            raise ArgumentError,
                  "#{tool_name}: integer property '#{name}' has no entry in " \
                  "Woods::MCP::ToolContract::INTEGER_BOUNDS; add '#{name}' => [minimum, maximum] " \
                  'to that table so the argument is bounded at the wire contract'
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
          if request[:name] == 'codebase_retrieve' && (arguments.key?(:limit) || arguments.key?('limit'))
            return contract_error(
              request[:name],
              'codebase_retrieve uses `budget` (token budget, default 8000), not `limit`.',
              code: :unsupported_argument,
              argument: 'limit'
            )
          end

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
