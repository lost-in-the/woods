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
      BUILDER_PATH = ROOT.join('lib/woods/builder.rb').freeze
      PUBLIC_DOCUMENTATION_PATHS = [ROOT.join('docs/README.md')].freeze

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
            'counts' => counts,
            'documentation_claims' => documentation_claims
          }
        end

        def write!
          INVENTORY_PATH.dirname.mkpath
          INVENTORY_PATH.write("#{JSON.pretty_generate(inventory)}\n")
        end

        def verify!
          actual = inventory
          verify_documentation_claims!(actual)

          expected = JSON.parse(INVENTORY_PATH.read)
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
          return if defined?(@release_rake_application) && @release_rake_application.equal?(Rake.application)

          load ROOT.join('lib/tasks/woods.rake') unless Rake::Task.task_defined?('woods:extract')
          load ROOT.join('lib/tasks/woods_evaluation.rake') unless Rake::Task.task_defined?('woods:evaluate')
          @release_rake_application = Rake.application
        end

        def executables
          ROOT.join('exe').children.select(&:file?).map { |path| path.basename.to_s }.sort
        end

        def index_mcp
          source = INDEX_SERVER_PATH.read
          {
            'tools' => index_tool_registrations(source),
            'resources' => resources(source),
            'resource_templates' => resource_templates(source)
          }
        end

        def index_tool_registrations(source)
          build_source = method_source(source, 'build')
          helper_registrations = build_source.each_line.filter_map do |line|
            match = line.match(/^\s*(define_[a-z_]+)\(.*?\)(?:\s+if\s+(.+))?$/)
            next unless match

            helper, condition = match.captures
            tool_names_for_helper(source, helper).map do |name|
              { 'name' => name, 'registration_condition' => condition || 'always registered' }
            end
          end
          traversal_registrations(build_source)
            .concat(helper_registrations.flatten)
            .sort_by { |tool| tool.fetch('name') }
        end

        def traversal_registrations(build_source)
          build_source.each_line.each_cons(5).filter_map do |lines|
            next unless lines.first.include?('define_traversal_tool(server')

            name = lines.join[/name:\s*'([^']+)'/, 1]
            { 'name' => name, 'registration_condition' => 'always registered' } if name
          end
        end

        def tool_names_for_helper(source, helper)
          helper_source = method_source(source, helper)
          names = helper_source.scan(/server\.define_tool\(\s*name:\s*'([^']+)'/m).flatten
          return names unless names.empty?

          helper_source.scan(/\b(define_[a-z_]+_tool)\(/).flatten
                       .flat_map { |nested_helper| tool_names_for_helper(source, nested_helper) }
                       .uniq
        end

        def method_source(source, name)
          source[/^\s*def #{Regexp.escape(name)}\b.*?(?=^\s*(?:def |private\b)|\z)/m].to_s
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
          builder_source = BUILDER_PATH.read
          {
            'embedding_providers' => adapter_keys(builder_source, 'build_embedding_provider'),
            'vector_stores' => adapter_keys(builder_source, 'build_vector_store'),
            'metadata_stores' => adapter_keys(builder_source, 'build_metadata_store'),
            'graph_stores' => adapter_keys(builder_source, 'build_graph_store'),
            'exporters' => exporter_implementations
          }
        end

        def adapter_keys(builder_source, method_name)
          method_source(builder_source, method_name).scan(/when :([a-z_]+)/).flatten.sort
        end

        def exporter_implementations
          ROOT.glob('lib/woods/**/*exporter.rb').sort.map do |path|
            {
              'name' => path.dirname.basename.to_s,
              'class' => path.read.scan(/^\s*(?:module|class)\s+([A-Z][A-Za-z0-9_:]*)/).flatten.join('::'),
              'path' => path.relative_path_from(ROOT).to_s
            }
          end
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

        def documentation_claims
          PUBLIC_DOCUMENTATION_PATHS.to_h do |path|
            source = path.read
            claims = {
              'extractor_registrations' => documented_count(source, /(\d+) extractors/),
              'index_mcp_tools' => documented_count(source, /(\d+)-tool index server/),
              'console_mcp_schemas' => documented_count(source, /(\d+)-tool console server/)
            }
            [path.relative_path_from(ROOT).to_s, claims]
          end
        end

        def documented_count(source, pattern)
          match = source.match(pattern)
          raise DriftError, "Current public documentation is missing #{pattern.inspect}." unless match

          match[1].to_i
        end

        def verify_documentation_claims!(actual)
          actual.fetch('documentation_claims').each do |path, claims|
            claims.each do |surface, documented_count|
              code_derived_count = actual.fetch('counts').fetch(surface)
              next if documented_count == code_derived_count

              raise DriftError,
                    "#{path} claims #{documented_count} #{surface}, but code derives #{code_derived_count}."
            end
          end
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
