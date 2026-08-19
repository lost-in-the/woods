# frozen_string_literal: true

require 'json'
require 'pathname'
require 'rake'
require 'woods'
require 'woods/extractor'
require 'woods/tasks'
require 'woods/console/server'

module Woods
  module ReleaseV2
    # Builds the release audit's public-surface contract from the authoritative
    # constants and registration source. The committed JSON is intentionally a
    # snapshot: `verify!` makes code and the release ledger move together.
    module SurfaceInventory # rubocop:disable Metrics/ModuleLength
      class DriftError < StandardError; end

      ROOT = Pathname.new(File.expand_path('../../..', __dir__)).freeze
      INVENTORY_PATH = ROOT.join('.Codex/release-v2/surface-inventory.json').freeze
      INDEX_SERVER_PATH = ROOT.join('lib/woods/mcp/server.rb').freeze

      INDEX_TOOL_CONDITIONS = {
        'session_trace' => 'Woods.configuration.session_store is configured',
        'pipeline_extract' => 'operator is provided',
        'pipeline_embed' => 'operator is provided',
        'pipeline_status' => 'operator is provided',
        'pipeline_diagnose' => 'operator is provided',
        'pipeline_repair' => 'operator is provided',
        'retrieval_rate' => 'feedback_store is provided',
        'retrieval_report_gap' => 'feedback_store is provided',
        'retrieval_explain' => 'feedback_store is provided',
        'retrieval_suggest' => 'feedback_store is provided',
        'list_snapshots' => 'snapshot_store is provided',
        'snapshot_diff' => 'snapshot_store is provided',
        'unit_history' => 'snapshot_store is provided',
        'snapshot_detail' => 'snapshot_store is provided',
        'notion_sync' => 'a resolved Notion token and non-empty database IDs are configured'
      }.freeze

      class << self # rubocop:disable Metrics/ClassLength
        def inventory
          {
            'schema_version' => 1,
            'generation' => {
              'command' => 'bundle exec rake release_v2:write_surface_inventory',
              'verification_command' => 'bundle exec rake release_v2:verify_surface_inventory',
              'serial_ledger_updates_required' => true
            },
            'configuration_attributes' => configuration_attributes,
            'presets' => presets,
            'extractor_registrations' => Woods::Extractor::EXTRACTORS.keys.map(&:to_s).sort,
            'rake_tasks' => rake_tasks,
            'executables' => executables,
            'index_mcp' => index_mcp,
            'console_mcp' => console_mcp,
            'tasks_methods' => Woods::Tasks.singleton_methods(false).map(&:to_s).sort,
            'adapters' => adapters,
            'public_woods_methods' => public_woods_methods,
            'counts' => counts
          }
        end

        def write!
          INVENTORY_PATH.dirname.mkpath
          INVENTORY_PATH.write("#{JSON.pretty_generate(inventory)}\n")
        end

        def verify!
          expected = JSON.parse(INVENTORY_PATH.read)
          actual = inventory
          return true if canonicalize(expected) == canonicalize(actual)

          raise DriftError,
                "#{INVENTORY_PATH.relative_path_from(ROOT)} is stale; run bundle exec rake " \
                'release_v2:write_surface_inventory and commit the resulting contract update.'
        end

        private

        def configuration_attributes
          Woods::Configuration.public_instance_methods(false)
                              .grep(/\A[a-z_]+=?\z/)
                              .map(&:to_s)
                              .sort
        end

        def presets
          Woods::Builder::PRESETS.keys.sort.to_h do |name|
            [name.to_s, Woods::Builder::PRESETS.fetch(name).transform_values(&:to_s)]
          end
        end

        def rake_tasks
          load_release_rake_tasks
          woods_tasks = Rake::Task.tasks.select { |task| task.name.start_with?('woods:') }
          task_definitions = woods_tasks.map do |task|
            {
              'name' => task.name,
              'arguments' => task.arg_names.map(&:to_s),
              'prerequisites' => task.prerequisites.sort
            }
          end
          task_definitions.sort_by { |task| task.fetch('name') }
        end

        def load_release_rake_tasks
          return if defined?(@release_rake_tasks_loaded) && @release_rake_tasks_loaded

          load ROOT.join('lib/tasks/woods.rake')
          load ROOT.join('lib/tasks/woods_evaluation.rake')
          @release_rake_tasks_loaded = true
        end

        def executables
          ROOT.join('exe').children.select(&:file?).map { |path| path.basename.to_s }.sort
        end

        def index_mcp
          source = INDEX_SERVER_PATH.read
          {
            'tools' => index_tool_names(source).map do |name|
              { 'name' => name, 'registration_condition' => INDEX_TOOL_CONDITIONS.fetch(name, 'always registered') }
            end,
            'resources' => resources(source),
            'resource_templates' => resource_templates(source)
          }
        end

        def index_tool_names(source)
          direct = source.scan(/server\.define_tool\(\s*name:\s*'([^']+)'/m).flatten
          traversals = source.each_line.each_cons(5).filter_map do |lines|
            next unless lines.first.include?('define_traversal_tool(server')

            lines.join[/name:\s*'([^']+)'/, 1]
          end
          (direct + traversals).sort
        end

        def resources(source)
          resource_section = source[/def build_resources(.*?)def define_woods_status_tool/m, 1]
          inventory_resource_entries(resource_section, 'uri')
        end

        def resource_templates(source)
          template_section = source[/def build_resource_templates(.*?)def build_resources/m, 1]
          inventory_resource_entries(template_section, 'uri_template')
        end

        def inventory_resource_entries(section, uri_key)
          section.scan(/#{uri_key}:\s*'([^']+)'.*?name:\s*'([^']+)'/m)
                 .map { |uri, name| { 'name' => name, uri_key => uri } }
                 .sort_by { |resource| resource.fetch('name') }
        end

        def console_mcp
          specs = Woods::Console::Server::TOOL_SPECS
          {
            'schemas' => specs.map { |spec| { 'name' => spec.name, 'tier' => spec.tier } }
                              .sort_by { |spec| spec['name'] },
            'tiers' => specs.group_by(&:tier).transform_keys(&:to_s).transform_values(&:count).sort.to_h
          }
        end

        def adapters
          {
            'embedding_providers' => %w[fake ollama openai],
            'vector_stores' => %w[in_memory pgvector qdrant],
            'metadata_stores' => %w[in_memory sqlite],
            'graph_stores' => ['in_memory'],
            'exporters' => [
              { 'name' => 'notion', 'class' => 'Woods::Notion::Exporter', 'path' => 'lib/woods/notion/exporter.rb' },
              { 'name' => 'obsidian', 'class' => 'Woods::Obsidian::VaultExporter',
                'path' => 'lib/woods/obsidian/vault_exporter.rb' },
              { 'name' => 'unblocked', 'class' => 'Woods::Unblocked::Exporter', 'path' => 'lib/woods/unblocked/exporter.rb' }
            ]
          }
        end

        def public_woods_methods
          Woods.singleton_methods(false).map(&:to_s).sort
        end

        def counts # rubocop:disable Metrics/AbcSize
          current = {
            'configuration_attributes' => configuration_attributes.count,
            'presets' => presets.count,
            'extractor_registrations' => Woods::Extractor::EXTRACTORS.count,
            'rake_tasks' => rake_tasks.count,
            'executables' => executables.count,
            'index_mcp_tools' => index_mcp.fetch('tools').count,
            'index_mcp_resources' => index_mcp.fetch('resources').count,
            'index_mcp_resource_templates' => index_mcp.fetch('resource_templates').count,
            'console_mcp_schemas' => console_mcp.fetch('schemas').count,
            'tasks_methods' => Woods::Tasks.singleton_methods(false).count,
            'public_woods_methods' => public_woods_methods.count
          }
          current.sort.to_h
        end

        def canonicalize(value)
          case value
          when Hash
            value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonicalize(value.fetch(key))] }
          when Array
            value.map { |entry| canonicalize(entry) }
          else
            value
          end
        end
      end
    end
  end
end
