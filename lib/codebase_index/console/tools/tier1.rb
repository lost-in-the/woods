# frozen_string_literal: true

module CodebaseIndex
  module Console
    module Tools
      # Tier 1: MVP read-only tools for querying live Rails data.
      #
      # Each method builds a bridge request hash from validated parameters.
      # The bridge executes the query against the Rails database.
      #
      module Tier1
        module_function

        # Count records matching scope conditions.
        #
        # @param model [String] Model name
        # @param scope [Hash, nil] Filter conditions
        # @return [Hash] Bridge request
        def console_count(model:, scope: nil)
          { tool: 'count', params: { model: model, scope: scope }.compact }
        end

        # Random sample of records.
        #
        # @param model [String] Model name
        # @param scope [Hash, nil] Filter conditions
        # @param limit [Integer] Max records (default: 5, max: 25)
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        def console_sample(model:, scope: nil, limit: 5, columns: nil)
          limit = [limit, 25].min
          { tool: 'sample', params: { model: model, scope: scope, limit: limit, columns: columns }.compact }
        end

        # Find a single record by primary key or unique column.
        #
        # @param model [String] Model name
        # @param id [Integer, nil] Primary key value
        # @param by [Hash, nil] Unique column lookup (e.g., { email: "x@y.com" })
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        def console_find(model:, id: nil, by: nil, columns: nil)
          { tool: 'find', params: { model: model, id: id, by: by, columns: columns }.compact }
        end

        # Extract column values.
        #
        # @param model [String] Model name
        # @param columns [Array<String>] Column names to pluck
        # @param scope [Hash, nil] Filter conditions
        # @param limit [Integer] Max records (default: 100, max: 1000)
        # @param distinct [Boolean] Return unique values only
        # @return [Hash] Bridge request
        def console_pluck(model:, columns:, scope: nil, limit: 100, distinct: false)
          limit = [limit, 1000].min
          { tool: 'pluck', params: { model: model, columns: columns, scope: scope,
                                     limit: limit, distinct: distinct }.compact }
        end

        # Run aggregate function on a column.
        #
        # @param model [String] Model name
        # @param function [String] One of: sum, avg, minimum, maximum
        # @param column [String] Column to aggregate
        # @param scope [Hash, nil] Filter conditions
        # @return [Hash] Bridge request
        def console_aggregate(model:, function:, column:, scope: nil)
          { tool: 'aggregate', params: { model: model, function: function, column: column, scope: scope }.compact }
        end

        # Count associated records.
        #
        # @param model [String] Model name
        # @param id [Integer] Record primary key
        # @param association [String] Association name
        # @param scope [Hash, nil] Filter on the association
        # @return [Hash] Bridge request
        def console_association_count(model:, id:, association:, scope: nil)
          { tool: 'association_count',
            params: { model: model, id: id, association: association, scope: scope }.compact }
        end

        # Get database schema for a model.
        #
        # @param model [String] Model name
        # @param include_indexes [Boolean] Include index information
        # @return [Hash] Bridge request
        def console_schema(model:, include_indexes: false)
          { tool: 'schema', params: { model: model, include_indexes: include_indexes } }
        end

        # Recently created/updated records.
        #
        # @param model [String] Model name
        # @param order_by [String] Column to sort by (default: created_at)
        # @param direction [String] Sort direction (default: desc)
        # @param limit [Integer] Max records (default: 10, max: 50)
        # @param scope [Hash, nil] Filter conditions
        # @param columns [Array<String>, nil] Columns to include
        # @return [Hash] Bridge request
        # rubocop:disable Metrics/ParameterLists
        def console_recent(model:, order_by: 'created_at', direction: 'desc', limit: 10, scope: nil, columns: nil)
          limit = [limit, 50].min
          { tool: 'recent', params: { model: model, order_by: order_by, direction: direction,
                                      limit: limit, scope: scope, columns: columns }.compact }
        end
        # rubocop:enable Metrics/ParameterLists

        # System health check.
        #
        # @return [Hash] Bridge request
        def console_status
          { tool: 'status', params: {} }
        end
      end
    end
  end
end
