# frozen_string_literal: true

require_relative 'shared'

module Woods
  module Notion
    module Mappers
      # Maps a model ExtractedUnit to Notion page properties for the Data Models database.
      #
      # Transforms model metadata (associations, validations, callbacks, scopes, git data)
      # into Notion API property format for the Data Models database.
      #
      # @example
      #   mapper = ModelMapper.new
      #   properties = mapper.map(unit_data)
      #   client.create_page(database_id: db_id, properties: properties)
      #
      class ModelMapper # rubocop:disable Metrics/ClassLength
        include Shared

        # Derive the table name for a model unit — the exact value the Data
        # Models page title is built from. Shared with the Columns sync so the
        # column title qualifier ("<table>.<column>") and the Table relation
        # always agree on which table a column belongs to (#149).
        #
        # Falls back to a naive tableized identifier when extraction produced
        # no table_name (close enough to ActiveRecord convention for a title).
        #
        # @param unit_data [Hash] Parsed model ExtractedUnit JSON
        # @return [String]
        def self.table_name_for(unit_data)
          metadata = unit_data['metadata'] || {}
          return metadata['table_name'] if metadata['table_name']

          identifier = unit_data['identifier'] || ''
          "#{identifier.split('::').last.to_s.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}s"
        end

        # Map a model unit to Notion Data Models page properties.
        #
        # @param unit_data [Hash] Parsed model ExtractedUnit JSON
        # @return [Hash] Notion page properties hash
        def map(unit_data)
          metadata = unit_data['metadata'] || {}
          properties = build_text_properties(unit_data, metadata)
          properties['Column Count'] = { number: column_count(metadata) }
          add_git_properties(properties, metadata['git'] || {})
          properties
        end

        private

        # @return [Hash] Text-based Notion properties
        def build_text_properties(unit_data, metadata)
          {
            'Table Name' => title_property(table_name(unit_data)),
            'Model Name' => rich_text_property(unit_data['identifier']),
            'Description' => rich_text_property(extract_description(unit_data['source_code'])),
            'Associations' => rich_text_property(format_associations(metadata['associations'])),
            'Validations' => rich_text_property(format_validations(metadata['validations'])),
            'Callbacks' => rich_text_property(format_callbacks(metadata['callbacks'])),
            'Scopes' => rich_text_property(format_scopes(metadata['scopes'])),
            'File Path' => rich_text_property(unit_data['file_path'] || ''),
            'Dependencies' => rich_text_property(format_dependencies(unit_data['dependencies']))
          }
        end

        # @return [void]
        def add_git_properties(properties, git)
          properties['Last Modified'] = { date: { start: git['last_modified'] } } if git['last_modified']
          properties['Change Frequency'] = { select: { name: git['change_frequency'] } } if git['change_frequency']
        end

        # @return [String]
        def table_name(unit_data)
          self.class.table_name_for(unit_data)
        end

        # @return [Integer]
        def column_count(metadata)
          metadata['column_count'] || (metadata['columns'] || []).size
        end

        # Extract the leading comment block from a model file, redacting
        # any credential-shaped content before shipping it to Notion.
        #
        # Model header comments occasionally contain sample API keys,
        # integration URLs with embedded passwords, or TODO references to
        # internal secrets. Without redaction those land verbatim in a
        # third-party SaaS database. This uses the same {CredentialScanner}
        # that protects the Console MCP so Notion export inherits the same
        # defenses.
        #
        # @return [String]
        def extract_description(source_code)
          return '' unless source_code

          comment_lines = []
          source_code.lines.each do |line|
            stripped = line.strip
            if stripped.start_with?('#')
              comment_lines << stripped.sub(/^#\s?/, '')
            elsif comment_lines.any?
              break
            end
          end

          return '' if comment_lines.empty?

          raw = comment_lines.join(' ').strip
          redact_credentials(raw)
        end

        def redact_credentials(text)
          return text if text.empty?

          # CredentialScanner#scan returns `[redacted_value, match_counts]`.
          # Unpack the tuple — returning the whole Array would serialize to
          # Notion as a stringified `["text...", {}]` blob.
          redacted, _counts = scanner.scan(text)
          redacted
        rescue StandardError
          # Scanner construction or scan failure — fail closed: return an
          # empty description rather than risk leaking anything.
          ''
        end

        def scanner
          @scanner ||= begin
            require 'woods/console/credential_scanner'
            Woods::Console::CredentialScanner.new
          end
        end

        # @return [String]
        def format_associations(associations)
          format_list(associations) { |items| items.map { |a| format_single_association(a) }.join("\n") }
        end

        # @return [String]
        def format_single_association(assoc)
          parts = ["#{assoc['type']} :#{assoc['name']}"]
          parts << "through: :#{assoc['through']}" if assoc['through']
          parts << "class_name: '#{assoc['class_name']}'" if assoc['class_name']
          parts << "foreign_key: :#{assoc['foreign_key']}" if assoc['foreign_key']
          parts.join(', ')
        end

        # @return [String]
        def format_validations(validations)
          format_list(validations) do |items|
            items.group_by { |v| v['attribute'] }.map do |attr, vals|
              "#{attr}: #{vals.map { |v| v['type'] }.join(', ')}"
            end.join("\n")
          end
        end

        # @return [String]
        def format_callbacks(callbacks)
          format_list(callbacks) { |items| items.map { |callback| format_single_callback(callback) }.join("\n") }
        end

        # @return [String]
        def format_single_callback(callback)
          parts = ["#{callback['type']}: #{callback['filter']}"]
          effects = callback_side_effects(callback['side_effects'])
          parts << "(#{effects.join('; ')})" if effects.any?
          parts.join(' ')
        end

        # @return [Array<String>]
        def callback_side_effects(side_effects)
          return [] unless side_effects

          effects = []
          jobs = side_effects['jobs_enqueued']
          effects << "enqueues #{jobs.join(', ')}" if jobs&.any?
          services = side_effects['services_called']
          effects << "calls #{services.join(', ')}" if services&.any?
          effects
        end

        # @return [String]
        def format_scopes(scopes)
          format_list(scopes) { |items| items.map { |s| s['name'] }.join(', ') }
        end

        # @return [String]
        def format_dependencies(dependencies)
          format_list(dependencies) { |items| items.map { |dep| "#{dep['target']} (via #{dep['via']})" }.join(', ') }
        end

        # @return [Hash]
        def title_property(text)
          { title: [{ text: { content: text } }] }
        end

        # Return 'None' for nil/empty lists; otherwise yield items to a formatting block.
        #
        # @param items [Array, nil]
        # @return [String]
        def format_list(items)
          return 'None' if items.nil? || items.empty?

          yield items
        end
      end
    end
  end
end
