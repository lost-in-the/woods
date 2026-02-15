# frozen_string_literal: true

require 'json'
require_relative 'model_validator'
require_relative 'safe_context'

module CodebaseIndex
  module Console
    # JSON-lines protocol bridge between MCP server and Rails environment.
    #
    # Reads JSON-lines requests from an input IO, validates model/column names,
    # dispatches to tool handlers, and writes JSON-lines responses to an output IO.
    #
    # Protocol:
    #   Request:  {"id":"req_1","tool":"count","params":{"model":"Order","scope":{"status":"pending"}}}
    #   Response: {"id":"req_1","ok":true,"result":{"count":1847},"timing_ms":12.3}
    #   Error:    {"id":"req_1","ok":false,"error":"Model not found","error_type":"validation"}
    #
    # @example
    #   bridge = Bridge.new(input: $stdin, output: $stdout,
    #                       model_validator: validator, safe_context: ctx)
    #   bridge.run
    #
    class Bridge
      SUPPORTED_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze

      # @param input [IO] Input stream (reads JSON-lines)
      # @param output [IO] Output stream (writes JSON-lines)
      # @param model_validator [ModelValidator] Validates model/column names
      # @param safe_context [SafeContext] Wraps execution in safe transaction
      def initialize(input:, output:, model_validator:, safe_context:)
        @input = input
        @output = output
        @model_validator = model_validator
        @safe_context = safe_context
      end

      # Read loop — processes requests until input is closed.
      #
      # @return [void]
      def run
        @input.each_line do |line|
          line = line.strip
          next if line.empty?

          request = parse_request(line)
          next unless request

          response = handle_request(request)
          write_response(response)
        end
      end

      # Process a single request hash and return a response hash.
      #
      # @param request [Hash] Parsed request with "id", "tool", "params"
      # @return [Hash] Response with "id", "ok", and "result" or "error"
      def handle_request(request)
        id = request['id']
        tool = request['tool']
        params = request['params'] || {}

        return error_response(id, "Unknown tool: #{tool}", 'unknown_tool') unless SUPPORTED_TOOLS.include?(tool)

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = dispatch(tool, params)
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        { 'id' => id, 'ok' => true, 'result' => result, 'timing_ms' => elapsed }
      rescue ValidationError => e
        error_response(id, e.message, 'validation')
      rescue StandardError => e
        error_response(id, e.message, 'execution')
      end

      private

      # Parse a JSON line into a request hash.
      #
      # @param line [String] Raw JSON line
      # @return [Hash, nil] Parsed request or nil on parse error
      def parse_request(line)
        JSON.parse(line)
      rescue JSON::ParserError => e
        write_response(error_response(nil, "Invalid JSON: #{e.message}", 'parse'))
        nil
      end

      # Dispatch a tool request to the appropriate handler.
      #
      # @param tool [String] Tool name
      # @param params [Hash] Tool parameters
      # @return [Hash] Tool result
      def dispatch(tool, params)
        case tool
        when 'status'
          handle_status
        when 'schema'
          handle_schema(params)
        else
          validate_model_param(params)
          send(:"handle_#{tool}", params)
        end
      end

      # Validate that the model parameter is present and known.
      def validate_model_param(params)
        model = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model

        @model_validator.validate_model!(model)
      end

      def handle_count(_params)
        { 'count' => 0 }
      end

      def handle_sample(_params)
        { 'records' => [] }
      end

      def handle_find(_params)
        { 'record' => nil }
      end

      def handle_pluck(params)
        @model_validator.validate_columns!(params['model'], params['columns']) if params['columns']
        { 'values' => [] }
      end

      def handle_aggregate(params)
        @model_validator.validate_column!(params['model'], params['column']) if params['column']
        { 'value' => nil }
      end

      def handle_association_count(_params)
        { 'count' => 0 }
      end

      def handle_schema(params)
        model = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model

        @model_validator.validate_model!(model)
        { 'columns' => @model_validator.columns_for(model), 'indexes' => [] }
      end

      def handle_recent(_params)
        { 'records' => [] }
      end

      def handle_status
        { 'status' => 'ok', 'models' => @model_validator.model_names }
      end

      # Build an error response hash.
      def error_response(id, message, error_type)
        { 'id' => id, 'ok' => false, 'error' => message, 'error_type' => error_type }
      end

      # Write a JSON-line response to the output stream.
      def write_response(response)
        @output.puts(JSON.generate(response))
        @output.flush
      end
    end
  end
end
