# frozen_string_literal: true

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class ValidationError < Woods::Error; end

    # Validates model names and column names against the Rails schema.
    #
    # In production, validates against AR::Base.descendants and model.column_names.
    # Accepts an injectable registry for testing without Rails.
    #
    # @example
    #   validator = ModelValidator.new(registry: { 'User' => %w[id email name] })
    #   validator.validate_model!('User')      # => true
    #   validator.validate_model!('Hacker')    # => raises ValidationError
    #   validator.validate_column!('User', 'email')  # => true
    #
    class ModelValidator
      # @param registry [Hash<String, Array<String>>] Model name => column names mapping
      # @param table_names [Hash<String, String>] Model name => table name mapping, used to
      #   resolve a qualified `table.column` reference back to the model that owns it. Optional
      #   and defaults to empty — callers that don't supply it get every qualified column
      #   reference rejected by {#validate_table_column!} (fail closed: an unmapped table can't
      #   be proven safe).
      def initialize(registry:, table_names: {})
        @registry = registry
        @model_by_table = table_names.each_with_object({}) { |(model, table), acc| acc[table.to_s] = model }
      end

      # Validate that a model name is known.
      #
      # @param model_name [String]
      # @return [true]
      # @raise [ValidationError] if model is unknown
      def validate_model!(model_name)
        return true if @registry.key?(model_name)

        raise ValidationError, "Unknown model: #{model_name}. Available: #{@registry.keys.sort.join(', ')}"
      end

      # Validate that a column exists on a model.
      #
      # @param model_name [String]
      # @param column_name [String]
      # @return [true]
      # @raise [ValidationError] if column is unknown
      def validate_column!(model_name, column_name)
        validate_model!(model_name)
        columns = @registry[model_name]
        return true if columns.include?(column_name)

        raise ValidationError,
              "Unknown column '#{column_name}' on #{model_name}. Available: #{columns.sort.join(', ')}"
      end

      # Validate multiple columns at once.
      #
      # @param model_name [String]
      # @param column_names [Array<String>]
      # @raise [ValidationError] if any column is unknown
      def validate_columns!(model_name, column_names)
        column_names.each { |col| validate_column!(model_name, col) }
      end

      # Validate a qualified `table.column` reference against the real
      # columns of the model that owns `table_name`. Table gating (TableGate)
      # only checks whether a table is *blocked*; it never confirms the
      # column exists on that table at all, so a syntactically valid but
      # nonexistent qualified column previously reached SQL execution and
      # failed as a generic adapter error instead of a typed one.
      #
      # @param table_name [String]
      # @param column_name [String]
      # @return [true]
      # @raise [ValidationError] if the table is unmapped or the column is unknown on it
      def validate_table_column!(table_name, column_name)
        model_name = @model_by_table[table_name.to_s]
        unless model_name
          raise ValidationError,
                "Unknown table '#{table_name}'. Cannot validate qualified column " \
                "'#{table_name}.#{column_name}'."
        end

        validate_column!(model_name, column_name)
      end

      # List all known model names.
      #
      # @return [Array<String>]
      def model_names
        @registry.keys.sort
      end

      # List columns for a model.
      #
      # @param model_name [String]
      # @return [Array<String>]
      def columns_for(model_name)
        validate_model!(model_name)
        @registry[model_name].sort
      end
    end
  end
end
