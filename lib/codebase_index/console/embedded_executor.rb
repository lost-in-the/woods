# frozen_string_literal: true

require_relative 'model_validator'
require_relative 'safe_context'

module CodebaseIndex
  module Console
    # Drop-in replacement for ConnectionManager + Bridge that executes
    # queries directly via ActiveRecord instead of a separate bridge process.
    #
    # Implements the same `send_request(Hash) -> Hash` interface as
    # ConnectionManager, so all existing tool definitions in Server work
    # unchanged — just pass this where `conn_mgr` goes.
    #
    # @example
    #   executor = EmbeddedExecutor.new(model_validator: validator, safe_context: ctx)
    #   response = executor.send_request({ 'tool' => 'count', 'params' => { 'model' => 'User' } })
    #   # => { 'ok' => true, 'result' => { 'count' => 42 }, 'timing_ms' => 1.2 }
    #
    class EmbeddedExecutor # rubocop:disable Metrics/ClassLength
      AGGREGATE_FUNCTIONS = %w[sum average minimum maximum].freeze

      TIER1_TOOLS = %w[count sample find pluck aggregate association_count schema recent status].freeze

      # @param model_validator [ModelValidator] Validates model/column names
      # @param safe_context [SafeContext] Wraps execution in rolled-back transaction
      # @param connection [Object, nil] Database connection for adapter detection
      def initialize(model_validator:, safe_context:, connection: nil)
        @model_validator = model_validator
        @safe_context = safe_context
        @connection = connection
      end

      # Execute a tool request and return a response hash.
      #
      # Compatible with ConnectionManager#send_request — Server's `send_to_bridge`
      # calls this method and expects `{ 'ok' => true/false, ... }`.
      #
      # @param request [Hash] Request with 'tool' and 'params' keys
      # @return [Hash] Response with 'ok', 'result'/'error', and 'timing_ms'
      def send_request(request)
        # Deep-stringify keys — Tier1 tool builders use symbol keys, but the bridge
        # path naturally stringifies via JSON round-trip. Replicate that here.
        request = deep_stringify_keys(request)
        tool = request['tool']
        params = request['params'] || {}

        unless TIER1_TOOLS.include?(tool)
          return { 'ok' => false,
                   'error' => 'Not yet implemented in embedded mode',
                   'error_type' => 'unsupported' }
        end

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @safe_context.execute { dispatch(tool, params) }
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        { 'ok' => true, 'result' => result, 'timing_ms' => elapsed }
      rescue ValidationError => e
        { 'ok' => false, 'error' => e.message, 'error_type' => 'validation' }
      rescue StandardError => e
        { 'ok' => false, 'error' => e.message, 'error_type' => 'execution' }
      end

      private

      # Route a tool name to its handler.
      #
      # @param tool [String] Tool name
      # @param params [Hash] Tool parameters
      # @return [Hash] Tool result
      def dispatch(tool, params)
        case tool
        when 'status'  then handle_status
        when 'schema'  then handle_schema(params)
        else
          validate_model!(params)
          send(:"handle_#{tool}", params)
        end
      end

      # @param params [Hash] Must contain 'model' key
      # @raise [ValidationError]
      def validate_model!(params)
        model = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model

        @model_validator.validate_model!(model)
      end

      # Resolve a model name string to an ActiveRecord class.
      #
      # @param name [String] Model class name (e.g., 'User', 'Admin::Account')
      # @return [Class] The ActiveRecord model class
      def resolve_model(name)
        name.constantize
      end

      # ── Tier 1 Handlers ──────────────────────────────────────────────────

      def handle_count(params)
        model = resolve_model(params['model'])
        scope = apply_scope(model, params['scope'])
        { 'count' => scope.count }
      end

      def handle_sample(params)
        model = resolve_model(params['model'])
        limit = [params.fetch('limit', 5).to_i, 25].min
        scope = apply_scope(model, params['scope'])
        scope = apply_columns(scope, params['columns'])
        records = scope.order(random_function).limit(limit)
        { 'records' => serialize_records(records, params['columns']) }
      end

      def handle_find(params)
        model = resolve_model(params['model'])
        record = if params['id']
                   model.find_by(id: params['id'])
                 elsif params['by']
                   model.find_by(params['by'])
                 end
        { 'record' => record ? serialize_record(record, params['columns']) : nil }
      end

      def handle_pluck(params)
        columns = params['columns']
        @model_validator.validate_columns!(params['model'], columns) if columns
        model = resolve_model(params['model'])
        limit = [params.fetch('limit', 100).to_i, 1000].min
        scope = apply_scope(model, params['scope'])
        scope = scope.distinct if params['distinct']
        values = scope.limit(limit).pluck(*columns.map(&:to_sym))
        { 'values' => values }
      end

      def handle_aggregate(params)
        column = params['column']
        function = params['function']
        @model_validator.validate_column!(params['model'], column) if column

        unless AGGREGATE_FUNCTIONS.include?(function)
          raise ValidationError, "Invalid aggregate function: #{function}. " \
                                 "Allowed: #{AGGREGATE_FUNCTIONS.join(', ')}"
        end

        model = resolve_model(params['model'])
        scope = apply_scope(model, params['scope'])
        { 'value' => scope.send(function.to_sym, column.to_sym) }
      end

      def handle_association_count(params)
        model = resolve_model(params['model'])
        record = model.find(params['id'])
        association_name = params['association']

        unless model.reflect_on_association(association_name.to_sym)
          raise ValidationError, "Unknown association '#{association_name}' on #{params['model']}"
        end

        scope = record.public_send(association_name)
        scope = apply_scope(scope, params['scope'])
        { 'count' => scope.count }
      end

      def handle_schema(params)
        model_name = params['model']
        raise ValidationError, 'Missing required parameter: model' unless model_name

        @model_validator.validate_model!(model_name)
        model = resolve_model(model_name)

        columns = model.columns_hash.transform_values do |col|
          { 'type' => col.type.to_s, 'null' => col.null, 'default' => col.default&.to_s }
        end

        result = { 'columns' => columns }

        if params['include_indexes']
          indexes = model.connection.indexes(model.table_name).map do |idx|
            { 'name' => idx.name, 'columns' => idx.columns, 'unique' => idx.unique }
          end
          result['indexes'] = indexes
        end

        result
      end

      def handle_recent(params)
        model = resolve_model(params['model'])
        order_by = params.fetch('order_by', 'created_at')
        direction = params.fetch('direction', 'desc')
        limit = [params.fetch('limit', 10).to_i, 50].min

        @model_validator.validate_column!(params['model'], order_by)
        direction = 'desc' unless %w[asc desc].include?(direction)

        scope = apply_scope(model, params['scope'])
        scope = apply_columns(scope, params['columns'])
        records = scope.order(order_by => direction.to_sym).limit(limit)
        { 'records' => serialize_records(records, params['columns']) }
      end

      def handle_status
        adapter = begin
          active_connection.adapter_name
        rescue StandardError
          'unknown'
        end
        { 'status' => 'ok', 'models' => @model_validator.model_names, 'adapter' => adapter }
      end

      # ── Helpers ──────────────────────────────────────────────────────────

      # Apply scope conditions (WHERE clauses) to a relation.
      #
      # @param relation [ActiveRecord::Relation, Class] Model or relation
      # @param scope [Hash, nil] Filter conditions
      # @return [ActiveRecord::Relation]
      def apply_scope(relation, scope)
        return relation unless scope.is_a?(Hash) && scope.any?

        relation.where(scope)
      end

      # Apply column selection to a relation.
      #
      # @param relation [ActiveRecord::Relation] The relation
      # @param columns [Array<String>, nil] Columns to select
      # @return [ActiveRecord::Relation]
      def apply_columns(relation, columns)
        return relation unless columns.is_a?(Array) && columns.any?

        relation.select(columns)
      end

      # Serialize a single record to a Hash.
      #
      # @param record [ActiveRecord::Base] The record
      # @param columns [Array<String>, nil] Columns to include
      # @return [Hash]
      def serialize_record(record, columns = nil)
        if columns.is_a?(Array) && columns.any?
          record.attributes.slice(*columns)
        else
          record.attributes
        end
      end

      # Serialize multiple records.
      #
      # @param records [ActiveRecord::Relation] The records
      # @param columns [Array<String>, nil] Columns to include
      # @return [Array<Hash>]
      def serialize_records(records, columns = nil)
        records.map { |r| serialize_record(r, columns) }
      end

      # DB-dialect-aware random ordering function.
      #
      # @return [Arel::Nodes::SqlLiteral]
      def random_function
        adapter = active_connection.adapter_name.downcase
        func = adapter.include?('mysql') ? 'RAND' : 'RANDOM'
        Arel.sql("#{func}()")
      end

      # Return the database connection (injected or from ActiveRecord).
      #
      # @return [Object] Database connection
      def active_connection
        @connection || ActiveRecord::Base.connection
      end

      # Recursively convert all Hash keys to strings.
      #
      # @param obj [Object] The object to stringify
      # @return [Object] Object with string keys
      def deep_stringify_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
        when Array
          obj.map { |item| deep_stringify_keys(item) }
        else
          obj
        end
      end
    end
  end
end
