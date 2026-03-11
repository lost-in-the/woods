# frozen_string_literal: true

# @see CodebaseIndex
module CodebaseIndex
  class Error < StandardError; end unless defined?(CodebaseIndex::Error)

  module Console
    class ValidationError < CodebaseIndex::Error; end

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
      def initialize(registry:)
        @registry = registry
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
      # @return [true]
      # @raise [ValidationError] if any column is unknown
      def validate_columns!(model_name, column_names) # rubocop:disable Naming/PredicateMethod
        column_names.each { |col| validate_column!(model_name, col) }
        true
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
