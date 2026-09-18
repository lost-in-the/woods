# frozen_string_literal: true

module Woods
  module Resilience
    class IndexValidator
      # Reuse the published reader's retention pin but inspect raw graph and
      # unit artifacts independently, without normalizing away bad records.
      module GraphChecks
        private

        def with_validation_payload
          root = Pathname.new(@index_dir)
          if root.join('manifest.json').exist? || root.join('generation.json').exist?
            Woods::PublishedIndex::GenerationCatalog.pointer(root)
            reader = Woods::MCP::IndexReader.new(root)
            reader.with_pinned_generation do
              @validation_payload = reader.payload_dir.to_s
              @validation_manifest = reader.manifest
              yield
            end
          else
            @validation_payload = @index_dir
            yield
          end
        ensure
          @validation_payload = nil
          @validation_manifest = nil
          @graph_index_entries = nil
        end

        def static_source_map?
          manifest = @validation_manifest
          manifest.is_a?(Hash) && manifest['provenance'].is_a?(Hash) &&
            manifest['provenance']['mode'] == 'woods_static_ruby_source'
        end

        def validation_index_entries(path, errors)
          entries = JSON.parse(Woods::AtomicFile.read(path))
          unless entries.is_a?(Array)
            errors << "#{path}: expected an array"
            return []
          end
          entries.select do |entry|
            valid = entry.is_a?(Hash) && entry['identifier'].is_a?(String) && !entry['identifier'].empty?
            errors << "#{path}: entry requires a nonempty identifier" unless valid
            valid
          end
        end

        def collect_graph_index_entry(type_dir, entry, data, errors)
          directory = File.basename(type_dir)
          types = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.fetch(directory)
          typed_entry = graph_index_entry(entry, data, types)
          @graph_index_entries << typed_entry
          return unless data

          file = find_unit_file(type_dir, entry['identifier'])
          unless data['identifier'] == entry['identifier'] && types.include?(data['type'])
            errors << "#{file}: expected typed unit #{typed_entry['type']}:#{entry['identifier']}"
            return
          end
          validate_graph_unit_path(file, entry, data, errors)
        end

        def graph_index_entry(entry, data, types)
          type = data && types.include?(data['type']) ? data['type'] : types.first
          result = entry.merge('type' => type)
          result['file_path'] = data['file_path'] if data&.key?('file_path') && !entry.key?('file_path')
          result
        end

        def validate_graph_unit_path(file, entry, data, errors)
          return unless entry.key?('file_path') && data.key?('file_path') && entry['file_path'] != data['file_path']

          errors << "#{file}: file_path differs from #{File.dirname(file)}/_index.json for #{entry['identifier']}"
        end
      end
    end
  end
end
