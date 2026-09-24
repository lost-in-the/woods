# frozen_string_literal: true

require 'digest'

module Woods
  module Watch
    class Installation
      # Validates portable ownership before any current file is changed.
      class Receipt
        attr_reader :data

        # @param document [Woods::AgentConfiguration::Document] portable receipt
        def initialize(document)
          @data = document.content && document.json
          validate! if data
        end

        # @return [Array<String>] portable paths recorded by this installation
        def paths
          return [] unless data

          data.fetch('files').keys + data.fetch('sections').keys
        end

        # @param document [Woods::AgentConfiguration::Document] owned file
        # @param expected [Hash] prior content fingerprint and mode
        # @return [void]
        def self.verify_file!(document, expected)
          actual = document.fingerprint
          # Git records the owner's executable bit, not the checkout's umask.
          # Plan snapshots separately retain exact modes for preview/apply drift.
          same_content = actual.slice('sha256', 'exists') == expected.slice('sha256', 'exists')
          same_executable = (actual.fetch('mode') & 0o100) == (expected.fetch('mode') & 0o100)
          return if same_content && same_executable

          raise Conflict, "Owned watcher file was edited or removed: #{document.path}"
        end

        private

        def validate!
          unless data['schema_version'] == 1 && data['selection'].is_a?(Hash) &&
                 %w[procfile puma external].include?(data.dig('selection', 'mode')) &&
                 data['files'].is_a?(Hash) && data['sections'].is_a?(Hash)
            raise Conflict, 'Malformed watcher installation receipt; restore its owned metadata'
          end

          validate_files!
          validate_sections!
        end

        def validate_files!
          data.fetch('files').each do |path, record|
            next if path == Layout::WRAPPER && valid_file_record?(record)

            raise Conflict, 'Invalid owned watcher executable in receipt'
          end
        end

        def validate_sections!
          data.fetch('sections').each do |path, record|
            valid_path = path == Layout::PUMA || Layout::PROCFILE.match?(path)
            next if valid_path && valid_section_record?(record)

            raise Conflict, 'Invalid owned watcher section in receipt'
          end
        end

        def valid_file_record?(record)
          record.is_a?(Hash) && record['exists'] == true && record['mode'] == 0o755 &&
            record['sha256'].is_a?(String) && record['sha256'].match?(/\A[0-9a-f]{64}\z/)
        end

        def valid_section_record?(record)
          record.is_a?(Hash) && [true, false].include?(record['created_file']) &&
            record['owned_text'].is_a?(String) && record['owned_text'].include?(Templates::START) &&
            record['owned_text'].include?(Templates::FINISH)
        end
      end
    end
  end
end
