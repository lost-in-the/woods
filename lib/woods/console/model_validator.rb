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
      # Most near matches named in an unknown model or column refusal.
      MAX_SUGGESTIONS = 5

      # @param registry [Hash<String, Array<String>>] Model name => column names mapping
      # @param table_names [Hash<String, String>] Model name => table name mapping, used to
      #   resolve a qualified `table.column` reference back to the model that owns it. Optional
      #   and defaults to empty — callers that don't supply it get every qualified column
      #   reference rejected by {#validate_table_column!} (fail closed: an unmapped table can't
      #   be proven safe).
      # @param hidden_tables [Array<String>] blocked tables (case-insensitive, bare names match any
      #   schema). Models on them are never suggested or counted in an unknown-model refusal.
      # @param hidden_columns [Array<String>] redacted columns (case-insensitive). Never suggested or
      #   counted in an unknown-column refusal. Validation itself is unchanged: a hidden name that
      #   exists still validates, and the executor's own refusals still apply to it.
      def initialize(registry:, table_names: {}, hidden_tables: [], hidden_columns: [])
        @registry = registry
        @model_by_table = table_names.each_with_object({}) { |(model, table), acc| acc[table.to_s] = model }
        @table_by_model = table_names.transform_keys(&:to_s).transform_values(&:to_s)
        @hidden_tables = Array(hidden_tables).map { |name| name.to_s.downcase }.reject(&:empty?)
        @hidden_columns = Array(hidden_columns).map { |name| name.to_s.downcase }
      end

      # Validate that a model name is known.
      #
      # @param model_name [String]
      # @return [true]
      # @raise [ValidationError] if model is unknown
      def validate_model!(model_name)
        return true if @registry.key?(model_name)

        known = @registry.keys.reject { |name| hidden_model?(name) }
        raise ValidationError, "Unknown model: #{model_name}.#{suggestion_text(model_name, known, 'model')}"
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

        known = columns.reject { |name| @hidden_columns.include?(name.to_s.downcase) }
        raise ValidationError,
              "Unknown column '#{column_name}' on #{model_name}.#{suggestion_text(column_name, known, 'column')}"
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

      # Return known table columns without guessing an unknown table's shape.
      # @param table_name [String]
      # @return [Array<String>, nil] nil when this table is not registered
      def columns_for_table(table_name)
        model = @model_by_table[table_name.to_s]
        @registry[model] if model
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

      private

      # " Did you mean: A, B? (N known models)" or " No close match among N known models."
      def suggestion_text(input, known, noun)
        counted = "#{known.size} known #{noun}#{'s' unless known.size == 1}"
        near = near_matches(input.to_s, known)
        return " No close match among #{counted}." if near.empty?

        " Did you mean: #{near.join(', ')}? (#{counted})"
      end

      # Up to {MAX_SUGGESTIONS} names, ordered by closeness then name so the
      # result never depends on registry insertion order.
      def near_matches(input, known)
        needle = input[0, 128].downcase
        known.filter_map { |name| (rank = closeness(needle, name.to_s.downcase)) && [rank, name.to_s] }
             .sort.first(MAX_SUGGESTIONS).map(&:last)
      end

      # Sortable closeness, or nil when the name is not close enough to suggest.
      def closeness(needle, candidate)
        return [0, 0] if needle == candidate
        return [1, 0] if candidate.start_with?(needle)
        return [2, 0] if contained?(needle, candidate)

        max = [2, needle.length / 3].max
        return nil if (needle.length - candidate.length).abs > max

        distance = edit_distance(needle, candidate)
        [3, distance] if distance <= max
      end

      def contained?(needle, candidate)
        return false if needle.length < 3 || candidate.length < 3

        candidate.include?(needle) || needle.include?(candidate)
      end

      def edit_distance(left, right)
        previous = (0..right.length).to_a
        left.each_char.with_index(1) do |lc, i|
          current = [i]
          right.each_char.with_index(1) do |rc, j|
            current << [previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (lc == rc ? 0 : 1)].min
          end
          previous = current
        end
        previous.last
      end

      def hidden_model?(model_name)
        table = @table_by_model[model_name.to_s]
        return false if table.nil? || @hidden_tables.empty?

        name = table.downcase
        @hidden_tables.include?(name) || @hidden_tables.include?(name.split('.').last)
      end
    end
  end
end
