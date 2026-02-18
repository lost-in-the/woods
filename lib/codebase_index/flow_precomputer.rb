# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'flow_assembler'

module CodebaseIndex
  # Orchestrates pre-computation of request flow maps for all controller actions.
  #
  # After the dependency graph is built, FlowPrecomputer iterates controller units,
  # runs FlowAssembler for each action, and writes flow documents to disk.
  #
  # @example
  #   precomputer = FlowPrecomputer.new(units: all_units, graph: dep_graph, output_dir: out)
  #   flow_map = precomputer.precompute
  #   flow_map["OrdersController#create"] #=> "/tmp/codebase_index/flows/OrdersController_create.json"
  #
  class FlowPrecomputer
    # Default maximum recursion depth for flow assembly
    DEFAULT_MAX_DEPTH = 3

    # @param units [Array<ExtractedUnit>] All extracted units
    # @param graph [DependencyGraph] The dependency graph
    # @param output_dir [String] Base output directory
    # @param max_depth [Integer] Maximum flow assembly depth
    def initialize(units:, graph:, output_dir:, max_depth: DEFAULT_MAX_DEPTH)
      @units = units
      @graph = graph
      @output_dir = output_dir
      @max_depth = max_depth
      @flows_dir = File.join(output_dir, 'flows')
    end

    # Pre-compute flow documents for all controller actions.
    #
    # @return [Hash{String => String}] Map of entry_point to flow file path
    def precompute
      FileUtils.mkdir_p(@flows_dir)

      assembler = FlowAssembler.new(graph: @graph, extracted_dir: @output_dir)
      flow_map = {}

      controller_units.each do |unit|
        actions = unit.metadata[:actions] || unit.metadata['actions'] || []
        unit_flow_paths = {}

        actions.each do |action|
          entry_point = "#{unit.identifier}##{action}"
          flow_path = assemble_and_write(assembler, entry_point, unit.identifier, action)
          next unless flow_path

          flow_map[entry_point] = flow_path
          unit_flow_paths[action] = flow_path
        end

        unit.metadata[:flow_paths] = unit_flow_paths if unit_flow_paths.any?
      end

      write_flow_index(flow_map)

      flow_map
    end

    private

    # Filter units to only controllers.
    #
    # @return [Array<ExtractedUnit>]
    def controller_units
      @units.select { |u| u.type.to_s == 'controller' }
    end

    # Assemble a flow for one entry point and write the JSON file.
    #
    # @param assembler [FlowAssembler]
    # @param entry_point [String]
    # @param controller_id [String]
    # @param action [String]
    # @return [String, nil] The written file path, or nil on failure
    def assemble_and_write(assembler, entry_point, controller_id, action)
      flow = assembler.assemble(entry_point, max_depth: @max_depth)

      filename = "#{controller_id.gsub('::', '__')}_#{action}.json"
      flow_path = File.join(@flows_dir, filename)

      File.write(flow_path, JSON.pretty_generate(flow.to_h))

      flow_path
    rescue StandardError => e
      Rails.logger.error("[CodebaseIndex] Flow precompute failed for #{entry_point}: #{e.message}")
      nil
    end

    # Write the flow index mapping entry points to file paths.
    #
    # @param flow_map [Hash{String => String}]
    def write_flow_index(flow_map)
      index_path = File.join(@flows_dir, 'flow_index.json')
      File.write(index_path, JSON.pretty_generate(flow_map))
    end
  end
end
