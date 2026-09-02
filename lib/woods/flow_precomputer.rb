# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'filename_utils'
require_relative 'flow_assembler'
require_relative 'atomic_file'

module Woods
  # Orchestrates pre-computation of request flow maps for all controller actions.
  #
  # After the dependency graph is built, FlowPrecomputer iterates controller units,
  # runs FlowAssembler for each action, and writes flow documents to disk.
  #
  # All persisted path values — `flow_index.json` entries and each controller
  # unit's `metadata[:flow_paths]` — are RELATIVE to the output dir
  # (e.g. "flows/OrdersController_create.json"), matching the #166 portability
  # contract: extraction inside a container must not bake `/app/...` prefixes
  # into artifacts a host reads through a volume mount, and identical trees at
  # different roots must produce identical bytes (which is also what keeps
  # {#canonical_json}'s churn-avoidance honest). Readers join the relative
  # value against their own index dir (see the MCP server's
  # `load_precomputed_flow`).
  #
  # @example
  #   precomputer = FlowPrecomputer.new(units: all_units, graph: dep_graph, output_dir: out)
  #   flow_map = precomputer.precompute
  #   flow_map["OrdersController#create"] #=> "flows/OrdersController_create.json"
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
    # Assembly is fail closed (M3 review round 3): a per-action failure
    # raises instead of skipping the entry, so a partial index — missing
    # entries alongside a freshly written graph — is never written and the
    # caller aborts before publishing. The full extraction path shares this
    # contract with the incremental delta.
    #
    # @return [Hash{String => String}] Map of entry_point to output_dir-relative
    #   flow file path (e.g. "flows/OrdersController_create.json")
    # @raise [Woods::ExtractionError] when any action fails to assemble
    def precompute
      FileUtils.mkdir_p(@flows_dir)

      assembler = FlowAssembler.new(graph: @graph, extracted_dir: @output_dir)
      flow_map = {}

      controller_units.each do |unit|
        entries, unit_flow_paths = assemble_controller_unit(assembler, unit)
        flow_map.merge!(entries)
        unit.metadata[:flow_paths] = unit_flow_paths if unit_flow_paths.any?
      end

      write_flow_index(flow_map)

      flow_map
    end

    # Recompute the flow documents for the controllers an incremental run
    # touched (M3), carrying every untouched controller's entries forward
    # from the previous generation's flow_index.json — payload seeding
    # hardlinks it into this run's payload directory — and rewriting the
    # index with the merged result.
    #
    # Touched controllers replace their previous entries wholesale (a full
    # run would emit exactly their current actions), so an action removed
    # from a re-extracted controller leaves the index even though the file
    # still exists. Controllers named in +removed_identifiers+ lost their
    # unit this run (deleted or renamed) and leave the index entirely;
    # {Woods::Extractor#sweep_orphaned_flow_files} then removes the
    # documents nothing references anymore.
    #
    # @param touched_units [Array<ExtractedUnit>] the run's re-extracted
    #   controller units, rehydrated from the payload this run seeded
    # @param removed_identifiers [Array<String>] controller identifiers
    #   whose unit the run pruned
    # @return [Hash{String => Hash{String => String}}] per-controller
    #   annotation (action => relative flow path) to write into the units'
    #   metadata; an empty hash means "no flows", which clears any
    #   annotation a previous run had written
    def recompute_delta(touched_units:, removed_identifiers: [])
      FileUtils.mkdir_p(@flows_dir)

      assembler = FlowAssembler.new(graph: @graph, extracted_dir: @output_dir)
      delta = {}
      annotations = {}

      touched_units.each do |unit|
        # A per-action skip would publish an index missing that entry, so
        # assembly raises. The incremental path must not advance publication
        # over a broken assembly; the caller aborts before the generation
        # bump.
        entries, unit_flow_paths = assemble_controller_unit(assembler, unit)
        annotations[unit.identifier] = unit_flow_paths
        delta.merge!(entries)
      end

      replaced = touched_units.map(&:identifier) + Array(removed_identifiers)
      carried = previous_flow_index.reject { |entry_point, _path| replaced.include?(controller_of(entry_point)) }

      write_flow_index(carried.merge(delta))

      annotations
    end

    private

    # Filter units to only controllers.
    #
    # @return [Array<ExtractedUnit>]
    def controller_units
      @units.select { |u| u.type.to_s == 'controller' }
    end

    # Assemble and write every flow for one controller unit.
    #
    # Both entry points fail closed: a per-action failure aborts the run
    # rather than publishing a flow index missing that entry (EXTB-14 — the
    # old `fail_closed:` switch documented a log-and-skip contract for the
    # full path that no caller ever asked for).
    #
    # @param assembler [FlowAssembler]
    # @param unit [ExtractedUnit]
    # @return [Array(Hash{String => String}, Hash{String => String})] the
    #   entry_point => relative-path entries for the flow index, and the
    #   action => relative-path annotation for the unit's metadata
    # @raise [Woods::ExtractionError] when an action fails to assemble
    def assemble_controller_unit(assembler, unit)
      entries = {}
      unit_flow_paths = {}

      actions = unit.metadata[:actions] || unit.metadata['actions'] || []
      actions.each do |action|
        entry_point = "#{unit.identifier}##{action}"
        flow_path = assemble_and_write(assembler, entry_point, unit.identifier, action)

        entries[entry_point] = flow_path
        unit_flow_paths[action] = flow_path
      end

      [entries, unit_flow_paths]
    end

    # The controller part of a flow index entry point.
    #
    # @param entry_point [String]
    # @return [String]
    def controller_of(entry_point)
      entry_point.to_s.split('#', 2).first
    end

    # The previous generation's flow index, or an empty hash when none was
    # published. A missing index means there is nothing to carry forward
    # (the caller established whether the family is genuinely absent); a
    # corrupt one raises — publication must not advance over unreadable
    # prior flow state.
    #
    # @return [Hash{String => String}]
    # @raise [Woods::ExtractionError] when the index does not parse
    def previous_flow_index
      path = File.join(@flows_dir, 'flow_index.json')
      return {} unless File.exist?(path)

      JSON.parse(Woods::AtomicFile.read(path))
    rescue JSON::ParserError => e
      raise Woods::ExtractionError, "previous flow_index.json does not parse: #{e.message}"
    end

    # Assemble a flow for one entry point and write the JSON file.
    #
    # Written via {Woods::AtomicFile} (temp + fsync + rename) like every
    # other index artifact — a plain +File.write+ interrupted mid-write left
    # a torn partial for the MCP read side to trip over.
    #
    # @param assembler [FlowAssembler]
    # @param entry_point [String]
    # @param controller_id [String]
    # @param action [String]
    # @return [String] The output_dir-relative path of the written file
    #   (e.g. "flows/OrdersController_create.json")
    # @raise [Woods::ExtractionError] when assembly or the write fails
    def assemble_and_write(assembler, entry_point, controller_id, action)
      flow = assembler.assemble(entry_point, max_depth: @max_depth)

      filename = Woods::FilenameUtils.flow_filename(controller_id, action)

      Woods::AtomicFile.write(File.join(@flows_dir, filename), canonical_json(flow.to_h))

      # Relative — this value is persisted (flow_index.json and the unit's
      # metadata[:flow_paths]), so it must not carry this machine's root.
      File.join('flows', filename)
    rescue StandardError => e
      raise Woods::ExtractionError, "flow precompute failed for #{entry_point}: #{e.message}"
    end

    # Write the flow index mapping entry points to output_dir-relative file paths.
    #
    # @param flow_map [Hash{String => String}]
    def write_flow_index(flow_map)
      index_path = File.join(@flows_dir, 'flow_index.json')
      Woods::AtomicFile.write(index_path, canonical_json(flow_map))
    end

    # Emit deterministic pretty JSON — keys recursively sorted so two runs
    # over identical input produce byte-identical output. Without this,
    # diff-based tooling (snapshot review, flow-change detection) flags
    # spurious churn from incidental key-order differences in `flow.to_h`.
    #
    # @param value [Hash, Array, Object]
    # @return [String]
    def canonical_json(value)
      JSON.pretty_generate(sort_keys_deep(value))
    end

    def sort_keys_deep(value)
      case value
      when Hash  then value.keys.sort_by(&:to_s).to_h { |k| [k, sort_keys_deep(value[k])] }
      when Array then value.map { |v| sort_keys_deep(v) }
      else value
      end
    end
  end
end
