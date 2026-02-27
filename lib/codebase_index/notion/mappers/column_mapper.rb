# frozen_string_literal: true

module CodebaseIndex
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
        # Map a single column to Notion Columns page properties.
        #
        # @param column [Hash] Column hash from metadata["columns"] (name, type, null, default)
        # @param model_identifier [String] Parent model name (for context)
        # @param validations [Array<Hash>] Model-level validations to match against this column
        # @param parent_page_id [String, nil] Notion page ID of the Data Models parent page
        # @return [Hash] Notion page properties hash
        def map(column, model_identifier: nil, validations: [], parent_page_id: nil) # rubocop:disable Lint/UnusedMethodArgument
          properties = {
            'Column Name' => { title: [{ text: { content: column['name'] } }] },
            'Data Type' => { select: { name: column['type'] } },
            'Nullable' => { checkbox: column['null'] == true },
            'Default Value' => rich_text_property(column['default'].to_s),
            'Validation Rules' => rich_text_property(format_validation_rules(column['name'], validations))
          }

          properties['Table'] = { relation: [{ id: parent_page_id }] } if parent_page_id

          properties
        end

        private

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

        # Build a Notion rich_text property.
        #
        # @param text [String]
        # @return [Hash]
        def rich_text_property(text)
          { rich_text: [{ text: { content: text.to_s } }] }
        end
      end
    end
  end
end
