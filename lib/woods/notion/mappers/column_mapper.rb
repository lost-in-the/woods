# frozen_string_literal: true

require_relative 'shared'

module Woods
  module Notion
    module Mappers
      # Maps individual column metadata to Notion page properties for the Columns database.
      #
      # Each column from a model's metadata becomes a separate Notion page, optionally
      # linked to its parent Data Models page via a relation property.
      #
      # @example
      #   mapper = ColumnMapper.new
      #   properties = mapper.map(column, model_identifier: "User", validations: [...], parent_page_id: "page-123")
      #
      class ColumnMapper
        include Shared

        # Map a single column to Notion Columns page properties.
        #
        # The page title is qualified as "<table>.<column>" (e.g. "users.id")
        # when a table name is given. Every Rails model shares id/created_at/
        # updated_at, and the Columns database is upserted by title — a bare
        # column-name title made every model overwrite every other model's
        # shared-name column pages (#149). The qualifier must come from
        # {ModelMapper.table_name_for} so it agrees with the Data Models page
        # the Table relation points at.
        #
        # @param column [Hash] Column hash from metadata["columns"] (name, type, null, default)
        # @param model_identifier [String] Parent model name (for context)
        # @param table_name [String, nil] Owning table name used to qualify the page title
        # @param validations [Array<Hash>] Model-level validations to match against this column
        # @param parent_page_id [String, nil] Notion page ID of the Data Models parent page
        # @return [Hash] Notion page properties hash
        def map(column, model_identifier: nil, table_name: nil, validations: [], parent_page_id: nil) # rubocop:disable Lint/UnusedMethodArgument
          properties = {
            'Column Name' => { title: [{ text: { content: qualified_title(column['name'], table_name) } }] },
            'Data Type' => { select: { name: column['type'] } },
            'Nullable' => { checkbox: column['null'] == true },
            'Default Value' => rich_text_property(column['default'].to_s),
            'Validation Rules' => rich_text_property(format_validation_rules(column['name'], validations))
          }

          properties['Table'] = { relation: [{ id: parent_page_id }] } if parent_page_id

          properties
        end

        private

        # Build the column page title, qualified by table when known.
        #
        # @param column_name [String]
        # @param table_name [String, nil]
        # @return [String] "<table>.<column>", or the bare name without a table
        def qualified_title(column_name, table_name)
          return column_name.to_s if table_name.nil? || table_name.to_s.empty?

          "#{table_name}.#{column_name}"
        end

        # Find and format validations matching this column name.
        #
        # @param column_name [String]
        # @param validations [Array<Hash>]
        # @return [String]
        def format_validation_rules(column_name, validations)
          matched = validations.select { |v| v['attribute'] == column_name }
          return 'None' if matched.empty?

          matched.map { |v| v['type'] }.join(', ')
        end
      end
    end
  end
end
