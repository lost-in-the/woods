# frozen_string_literal: true

require 'json'
require 'pathname'
require 'woods/erd/entry_point_index_builder'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Erd
    # Transforms Woods extracted model units into Liam ERD's schema.json format.
    #
    # Reads model unit JSON files from the extraction output directory and
    # produces a schema conforming to Liam's schemaSchema: tables with columns,
    # indexes, and constraints (primary keys, foreign keys).
    #
    # @example
    #   generator = SchemaGenerator.new("/app/tmp/woods")
    #   schema = generator.generate
    #   # => { "tables" => { "posts" => { ... } }, "enums" => {}, "extensions" => {} }
    #
    class SchemaGenerator
      LAYER_DIRECTORIES = {
        controllers: 'controllers',
        jobs: 'jobs',
        services: 'services',
        mailers: 'mailers'
      }.freeze

      # @param output_dir [String, Pathname] Path to Woods extraction output directory
      # @param layers [Array<Symbol>] Active layers to include (default: [:models])
      def initialize(output_dir, layers: [:models])
        @output_dir = Pathname.new(output_dir)
        @layers = layers
      end

      # Generate a Liam-compatible schema hash from extracted model units.
      #
      # @return [Hash] Schema with tables, enums, extensions, and optionally nodes keys
      # @raise [Woods::Error] if no extracted model data is found
      def generate
        models_dir = @output_dir.join('models')
        raise Woods::Error, 'No extracted model data found in output directory' unless models_dir.directory?

        units = load_model_units(models_dir)
        tables = build_tables(units)
        enums = build_enums(units)

        schema = { 'tables' => tables, 'enums' => enums, 'extensions' => {} }

        non_model_layers = @layers.reject { |l| l == :models }
        unless non_model_layers.empty?
          table_lookup = build_table_lookup(units)
          nodes = build_nodes(non_model_layers, table_lookup)
          schema['nodes'] = nodes unless nodes.empty?
        end

        entry_points = EntryPointIndexBuilder.new(@output_dir).build
        schema['entryPoints'] = entry_points unless entry_points.empty?

        schema
      end

      private

      def load_model_units(models_dir)
        models_dir.children
                  .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                  .map { |f| JSON.parse(f.read) }
      end

      def build_tables(units)
        tables = {}

        prioritize_base_models(units).each do |unit|
          meta = unit['metadata'] || {}
          table_name = meta['table_name']
          next if table_name.nil?
          next unless meta['table_exists']
          next if tables.key?(table_name) # STI dedup: first model wins

          tables[table_name] = build_table(table_name, meta, units)
        end

        tables
      end

      # Sort STI base models first so dedup keeps the base model's metadata
      def prioritize_base_models(units)
        units.sort_by { |u| u.dig('metadata', 'is_sti_child') ? 1 : 0 }
      end

      def build_table(table_name, meta, all_units)
        {
          'name' => table_name,
          'comment' => nil,
          'columns' => build_columns(meta['columns'] || []),
          'indexes' => build_indexes(meta['indexes'] || []),
          'constraints' => build_constraints(table_name, meta, all_units)
        }
      end

      def build_columns(columns)
        columns.each_with_object({}) do |col, hash|
          name = col['name']
          hash[name] = {
            'name' => name,
            'type' => col['type'] || 'unknown',
            'default' => col['default'],
            'check' => nil,
            'notNull' => !col['null'],
            'comment' => nil
          }
        end
      end

      def build_indexes(indexes)
        indexes.each_with_object({}) do |idx, hash|
          name = idx['name']
          hash[name] = {
            'name' => name,
            'unique' => idx['unique'] || false,
            'columns' => idx['columns'] || [],
            'type' => ''
          }
        end
      end

      def build_constraints(table_name, meta, all_units)
        constraints = {}

        pk = meta['primary_key']
        if pk
          pk_name = "#{table_name}_pkey"
          constraints[pk_name] = {
            'type' => 'PRIMARY KEY',
            'name' => pk_name,
            'columnNames' => Array(pk)
          }
        end

        if meta.key?('foreign_keys') && !meta['foreign_keys'].empty?
          build_foreign_keys_from_metadata(meta['foreign_keys'], constraints)
        else
          build_foreign_keys_from_associations(table_name, meta, all_units, constraints)
        end

        constraints
      end

      def build_foreign_keys_from_metadata(foreign_keys, constraints)
        foreign_keys.each do |fk|
          name = fk['name'] || "fk_#{fk['from_table']}_#{fk['column']}"
          constraints[name] = {
            'type' => 'FOREIGN KEY',
            'name' => name,
            'columnNames' => [fk['column']],
            'targetTableName' => fk['to_table'],
            'targetColumnNames' => [fk['primary_key'] || 'id'],
            'updateConstraint' => map_fk_action(fk['on_update']),
            'deleteConstraint' => map_fk_action(fk['on_delete'])
          }
        end
      end

      def build_foreign_keys_from_associations(table_name, meta, all_units, constraints)
        associations = meta['associations'] || []
        table_lookup = build_table_lookup(all_units)

        associations.each do |assoc|
          next unless assoc['type'].to_s == 'belongs_to'
          next if assoc['polymorphic']

          foreign_key = assoc['foreign_key']
          target_table = table_lookup[assoc['target']]
          next unless target_table

          name = "fk_#{table_name}_#{foreign_key}"
          constraints[name] = {
            'type' => 'FOREIGN KEY',
            'name' => name,
            'columnNames' => [foreign_key],
            'targetTableName' => target_table,
            'targetColumnNames' => ['id'],
            'updateConstraint' => 'NO_ACTION',
            'deleteConstraint' => 'NO_ACTION'
          }
        end
      end

      def build_table_lookup(units)
        units.each_with_object({}) do |unit, lookup|
          meta = unit['metadata'] || {}
          next unless meta['table_exists']

          lookup[unit['identifier']] = meta['table_name']
        end
      end

      def build_enums(units)
        enums = {}

        units.each do |unit|
          model_enums = unit.dig('metadata', 'enums') || {}
          model_enums.each do |name, values|
            qualified_name = "#{unit['identifier']}.#{name}"
            enums[qualified_name] = {
              'name' => qualified_name,
              'values' => values.is_a?(Hash) ? values.keys : Array(values),
              'comment' => nil
            }
          end
        end

        enums
      end

      def map_fk_action(action)
        case action.to_s
        when 'cascade' then 'CASCADE'
        when 'restrict' then 'RESTRICT'
        when 'nullify', 'set_null' then 'SET_NULL'
        when 'set_default' then 'SET_DEFAULT'
        else 'NO_ACTION'
        end
      end

      def build_nodes(layers, table_lookup)
        nodes = {}

        layers.each do |layer|
          dir_name = LAYER_DIRECTORIES[layer]
          next unless dir_name

          layer_dir = @output_dir.join(dir_name)
          next unless layer_dir.directory?

          layer_dir.children
                   .select { |f| f.extname == '.json' && f.basename.to_s != '_index.json' }
                   .each do |file|
                     unit = JSON.parse(file.read)
                     node = build_node(unit, layer, table_lookup)
                     nodes[unit['identifier']] = node
                   end
        end

        nodes
      end

      def build_node(unit, layer, table_lookup)
        meta = unit['metadata'] || {}
        deps = unit['dependencies'] || []

        {
          'name' => unit['identifier'],
          'type' => layer.to_s.delete_suffix('s'),
          'members' => build_node_members(layer, meta),
          'meta' => build_node_meta(layer, meta),
          'dependencies' => build_node_dependencies(deps, table_lookup)
        }
      end

      def build_node_members(layer, meta)
        actions = case layer
                  when :controllers, :mailers
                    meta['actions'] || []
                  when :jobs
                    meta['perform_params'] || []
                  when :services
                    meta['public_methods'] || []
                  else
                    []
                  end

        actions.map do |a|
          name = a.is_a?(Hash) ? (a['name'] || a[:name]).to_s : a.to_s
          { 'name' => name }
        end
      end

      def build_node_meta(layer, meta)
        case layer
        when :controllers
          { 'action_count' => meta['action_count'] || 0 }
        when :jobs
          result = {}
          result['queue'] = meta['queue'] if meta.key?('queue')
          result['job_type'] = meta['job_type'] if meta.key?('job_type')
          result
        when :services
          meta['is_callable'] ? { 'callable' => true } : {}
        when :mailers
          result = {}
          result['delivery_method'] = meta['delivery_method'] if meta.key?('delivery_method')
          result['action_count'] = meta['action_count'] if meta.key?('action_count')
          result
        else
          {}
        end
      end

      def build_node_dependencies(deps, table_lookup)
        deps.map do |dep|
          target = dep['target']
          resolved_target = table_lookup[target]

          if resolved_target
            { 'target' => resolved_target, 'target_type' => 'table', 'via' => dep['via'] }
          else
            { 'target' => target, 'target_type' => dep['type'], 'via' => dep['via'] }
          end
        end
      end
    end
  end
end
