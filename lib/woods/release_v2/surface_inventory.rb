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
      DOCUMENTATION_INDEX_PATH = ROOT.join('docs/README.md').freeze
      DOCUMENTATION_SURFACE_CLAIM_PATTERNS = [
        { surface: 'extractor_registrations', pattern: /(?<count>\d+) extractors\b/i },
        { surface: 'index_mcp_tools', pattern: /\b(?:MCP )?Index Server\b[^\n]{0,40}?\b(?<count>\d+) tools\b/i },
        { surface: 'index_mcp_tools', pattern: /\b(?<count>\d+) tools, 2 resources, 2 templates\b/i },
        { surface: 'index_mcp_tools', pattern: /\b(?<count>\d+)-tool index server\b/i },
        { surface: 'index_mcp_tools', pattern: /\b(?<count>\d+) tools for code lookup, dependency traversal\b/i },
        {
          surface: 'index_mcp_tools',
          pattern: /\bprovides (?<count>\d+) tools for querying extracted codebase structure\b/i
        },
        { surface: 'index_mcp_tools', pattern: /\bTools\s*\(\s*(?<count>\d+)\s*[—-]/i },
        { surface: 'console_mcp_schemas', pattern: /\bTools\s*\(\s*(?<count>\d+)\s*\)\s*$/i },
        { surface: 'console_mcp_schemas', pattern: /\bTool inventory\s*\(\s*(?<count>\d+)\s+schemas\b/i },
        { surface: 'console_mcp_schemas', pattern: /\bConsole Server(?:\*{2})?\s*\(\s*(?<count>\d+) tools\b/i },
        { surface: 'console_mcp_schemas', pattern: /\bConsole Server\b[^\n]{0,120}?\bprovides (?<count>\d+) tools\b/i },
        { surface: 'console_mcp_schemas', pattern: /\b(?<count>\d+)-tool console server\b/i },
        { surface: 'console_mcp_schemas', pattern: /\b(?<count>\d+) tools for querying real database records\b/i },
        {
          surface: 'console_mcp_schemas',
          pattern: /\b(?:all|for all) (?<count>\d+) tools(?:,| across all 4 tiers| require)/i
        },
        { surface: 'console_mcp_schemas', pattern: /\bfull (?<count>\d+)-tool surface\b/i },
        { surface: 'console_mcp_schemas', pattern: /\bBridge \((?<count>\d+) tools\)/i },
        { surface: 'console_mcp_schemas', pattern: /\b(?<count>\d+) tools, live Rails\b/i },
        {
          surface: 'console_mcp_default_tools',
          pattern: /\bTool inventory\s*\(\s*\d+\s+schemas;\s*(?<count>\d+)\s+registered by default\b/i
        },
        {
          surface: 'console_mcp_read_tools',
          pattern: /\b(?<count>\d+)\s+with read tools(?: enabled)?\b/i
        },
        { surface: 'index_mcp_resources', pattern: /(?<count>\d+) resources\b/i },
        { surface: 'index_mcp_resource_templates', pattern: /(?<count>\d+) templates\b/i }
      ].freeze

      class << self # rubocop:disable Metrics/ClassLength
        # Inventoried files carry multibyte comment characters; a bare
        # Pathname#read tags them with the process default external encoding,
        # which is US-ASCII under LANG=C and breaks every regex scan below.
        def read_utf8(path)
          path.read(encoding: Encoding::UTF_8)
        end

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

          expected = JSON.parse(read_utf8(INVENTORY_PATH))
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
          source = read_utf8(INDEX_SERVER_PATH)
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
            tool_registrations_for_helper(source, helper).map do |registration|
              condition_contract = registration_condition(
                source,
                build_source,
                helper,
                condition,
                registration.fetch('internal_guards')
              )
              registration.merge('registration_condition' => condition_contract)
            end
          end
          traversal_registrations(source, build_source)
            .concat(helper_registrations.flatten)
            .sort_by { |tool| tool.fetch('name') }
        end

        def traversal_registrations(source, build_source)
          build_source.each_line.each_cons(5).filter_map do |lines|
            next unless lines.first.include?('define_traversal_tool(server')

            name = lines.join[/name:\s*'([^']+)'/, 1]
            next unless name

            {
              'name' => name,
              'internal_guards' => [],
              'registration_condition' => registration_condition(source, build_source, 'define_traversal_tool', nil, [])
            }
          end
        end

        def tool_registrations_for_helper(source, helper)
          helper_source = method_source(source, helper)
          names = helper_source.scan(/server\.define_tool\(\s*name:\s*'([^']+)'/m).flatten
          return names.map { |name| { 'name' => name, 'internal_guards' => [] } } unless names.empty?

          registrations = helper_source.each_line.filter_map do |line|
            match = line.match(/^\s*(define_[a-z_]+_tool)\(.*?\)(?:\s+if\s+(.+))?$/)
            next unless match

            nested_helper, guard = match.captures
            tool_registrations_for_helper(source, nested_helper).map do |registration|
              registration.merge('internal_guards' => registration.fetch('internal_guards') + Array(guard))
            end
          end.flatten
          registrations.uniq { |registration| registration.fetch('name') }
        end

        def registration_condition(source, build_source, helper, call_site_guard, internal_guards)
          {
            'call_site_guard' => call_site_guard || 'always registered',
            'predicate_logic' => predicate_logic(source, call_site_guard),
            'predicate_definitions' => predicate_definitions(source, call_site_guard),
            'internal_guards' => internal_guards,
            'registration_logic' => registration_logic(source, build_source, helper)
          }
        end

        def predicate_logic(source, guard)
          return nil unless guard&.match?(/\A[a-z_]+\?\z/)

          normalize_logic(method_source(source, guard))
        end

        def predicate_definitions(source, guard)
          predicate_names = guard.to_s.scan(/\b([a-z_][a-z_0-9]*[!?])(?=\s*(?:\(|&&|\|\||\z))/).flatten.uniq
          definitions = predicate_names.to_h do |name|
            [name, normalize_logic(method_source(source, name))]
          end
          definitions.reject { |_name, logic| logic.empty? }
        end

        def registration_logic(source, build_source, helper)
          [normalize_logic(build_source), normalize_logic(method_source(source, helper))].join("\n")
        end

        def normalize_logic(source)
          source.each_line.reject { |line| line.strip.start_with?('#') }.join.gsub(/\s+/, ' ').strip
        end

        def method_source(source, name)
          source[/^\s*def #{Regexp.escape(name)}(?![A-Za-z0-9_]).*?(?=^\s*def |\z)/m].to_s
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
            'tiers' => specs.group_by(&:tier).transform_keys(&:to_s).transform_values(&:count).sort.to_h,
            'executable_modes' => console_executable_modes
          }
        end

        def console_executable_modes
          Woods::Console::Server::EXECUTABLE_MODES.keys.sort.to_h do |mode|
            names = Woods::Console::Server::CONTRACT_MATRIX.filter_map do |row|
              row.fetch(:name) if row.fetch(:executable_modes).include?(mode)
            end
            [mode.to_s, names.sort]
          end
        end

        def adapters
          builder_source = read_utf8(BUILDER_PATH)
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
              'class' => read_utf8(path).scan(/^\s*(?:module|class)\s+([A-Z][A-Za-z0-9_:]*)/).flatten.join('::'),
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
            'console_mcp_default_tools' => console_mcp.fetch('executable_modes').fetch('embedded').count,
            'console_mcp_read_tools' => console_mcp.fetch('executable_modes').fetch('embedded_read').count,
            'tasks_methods' => Woods::Tasks.singleton_methods(false).count,
            'public_woods_methods' => public_woods_methods.count
          }
          current.sort.to_h
        end

        def documentation_claims
          current_public_documentation_paths.to_h do |path|
            [path.relative_path_from(ROOT).to_s, documented_surface_claims(read_utf8(path))]
          end
        end

        def current_public_documentation_paths
          ([ROOT.join('README.md'), DOCUMENTATION_INDEX_PATH] + indexed_current_guides).uniq.sort
        end

        def indexed_current_guides
          read_utf8(DOCUMENTATION_INDEX_PATH).scan(/\]\(([^)#]+\.md)\)/).flatten.filter_map do |reference|
            path = DOCUMENTATION_INDEX_PATH.dirname.join(reference).cleanpath
            path if current_guide?(path)
          end
        end

        def current_guide?(path)
          return false unless path.file? && path.dirname == DOCUMENTATION_INDEX_PATH.dirname

          heading = read_utf8(path).lines.first(4).join
          !heading.match?(/\b(?:retrospective|design doc|spike)\b/i)
        end

        def documented_surface_claims(source)
          paired_server_claims(source) + DOCUMENTATION_SURFACE_CLAIM_PATTERNS.flat_map do |rule|
            source.scan(rule.fetch(:pattern)).map do |match|
              { 'surface' => rule.fetch(:surface), 'count' => match.first.to_i }
            end
          end
        end

        def paired_server_claims(source)
          paired_counts = source.scan(/both MCP servers\s*\(\s*(?<index>\d+)\s*\+\s*(?<console>\d+) tools\)/i)
          paired_counts += source.scan(/\|\s+\*\*Tools\*\*\s+\|\s+(?<index>\d+)\s+\([^|]+\|\s+(?<console>\d+)\s+\(/)

          paired_counts.flat_map do |match|
            [
              { 'surface' => 'index_mcp_tools', 'count' => match[0].to_i },
              { 'surface' => 'console_mcp_schemas', 'count' => match[1].to_i }
            ]
          end
        end

        def verify_documentation_claims!(actual)
          actual.fetch('documentation_claims').each do |path, claims|
            claims.each do |claim|
              surface = claim.fetch('surface')
              documented_count = claim.fetch('count')
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
