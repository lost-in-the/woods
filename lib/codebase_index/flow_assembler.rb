# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'ast/parser'
require_relative 'ast/method_extractor'
require_relative 'flow_analysis/operation_extractor'
require_relative 'flow_document'

module CodebaseIndex
  # Orchestrates execution flow tracing from an entry point through the dependency graph.
  #
  # Given an entry point (e.g., "PostsController#create"), FlowAssembler:
  # 1. Loads the ExtractedUnit JSON from disk
  # 2. Parses its source_code with the AST layer
  # 3. Extracts operations in source line order
  # 4. Recursively expands targets that resolve to other units
  # 5. Detects cycles and respects max_depth
  # 6. Assembles a FlowDocument
  #
  # @example Assembling a flow
  #   assembler = FlowAssembler.new(graph: graph, extracted_dir: "/tmp/codebase_index")
  #   flow = assembler.assemble("PostsController#create", max_depth: 5)
  #   puts flow.to_markdown
  #
  class FlowAssembler
    # @param graph [DependencyGraph] The dependency graph for resolving targets
    # @param extracted_dir [String] Directory containing extracted unit JSON files
    def initialize(graph:, extracted_dir:)
      @graph = graph
      @extracted_dir = extracted_dir
      @parser = Ast::Parser.new
      @method_extractor = Ast::MethodExtractor.new(parser: @parser)
      @operation_extractor = FlowAnalysis::OperationExtractor.new
    end

    # Assemble an execution flow from the given entry point.
    #
    # @param entry_point [String] Unit identifier, optionally with #method_name
    # @param max_depth [Integer] Maximum recursion depth
    # @return [FlowDocument] The assembled flow document
    def assemble(entry_point, max_depth: 5)
      visited = Set.new
      steps = []

      expand(entry_point, steps, visited, depth: 0, max_depth: max_depth)

      route = extract_route(entry_point)

      FlowDocument.new(
        entry_point: entry_point,
        route: route,
        max_depth: max_depth,
        steps: steps
      )
    end

    private

    # Recursively expand a unit into flow steps.
    #
    # @param identifier [String] Unit identifier (may include #method)
    # @param steps [Array<Hash>] Accumulator for step hashes
    # @param visited [Set<String>] Visited unit identifiers for cycle detection
    # @param depth [Integer] Current recursion depth
    # @param max_depth [Integer] Maximum recursion depth
    def expand(identifier, steps, visited, depth:, max_depth:)
      return if depth > max_depth

      # Parse identifier into unit name and optional method
      unit_id, method_name = parse_identifier(identifier)

      if visited.include?(unit_id)
        # Cycle detected - emit a marker step
        steps << {
          unit: unit_id,
          type: 'cycle',
          operations: [{ type: :cycle, target: unit_id, line: nil }]
        }
        return
      end

      visited.add(unit_id)

      # Load the unit data from disk
      unit_data = load_unit(unit_id)
      return unless unit_data

      source_code = unit_data[:source_code]
      return unless source_code && !source_code.empty?

      metadata = unit_data[:metadata] || {}
      unit_type = unit_data[:type]&.to_s
      file_path = unit_data[:file_path]

      # Extract operations from the relevant method
      operations = extract_operations(source_code, method_name, metadata, unit_type)

      step = {
        unit: identifier,
        type: unit_type,
        file_path: file_path,
        operations: operations
      }

      steps << step

      # Recursively expand targets that resolve to known units
      operations.each do |op|
        expand_operation(op, identifier, steps, visited, depth: depth, max_depth: max_depth)
      end
    end

    # Extract operations from source code for a specific method.
    def extract_operations(source_code, method_name, metadata, unit_type)
      operations = []

      # For controllers, prepend before_action callbacks
      prepend_callbacks(operations, metadata, method_name) if unit_type == 'controller'

      if method_name
        # Extract specific method
        method_node = @method_extractor.extract_method(source_code, method_name)
        if method_node
          ops = @operation_extractor.extract(method_node)
          operations.concat(ops)
        end
      else
        # No specific method - parse entire source
        root = @parser.parse(source_code)
        ops = @operation_extractor.extract(root)
        operations.concat(ops)
      end

      operations
    end

    # Prepend before_action callbacks from controller metadata.
    #
    # Handles two metadata formats:
    # - metadata[:callbacks] with :name key (legacy/test format)
    # - metadata[:filters] with :filter key (ControllerExtractor format)
    def prepend_callbacks(operations, metadata, method_name)
      callbacks = metadata[:callbacks] || metadata[:filters]
      return unless callbacks.is_a?(Array)

      callbacks.each do |cb|
        cb_kind = cb[:kind]&.to_s
        next unless cb_kind == 'before'

        # Handle both :name (callbacks format) and :filter (controller filters format)
        cb_name = cb[:name] || cb[:filter]
        next unless cb_name

        # Check if callback applies to this action (via :only/:except)
        only = cb[:only]
        except = cb[:except]

        next if only.is_a?(Array) && method_name && !only.map(&:to_s).include?(method_name.to_s)

        next if except.is_a?(Array) && method_name && except.map(&:to_s).include?(method_name.to_s)

        operations << {
          type: :call,
          target: nil,
          method: cb_name.to_s,
          line: nil
        }
      end
    end

    # Recursively expand an operation's target if it resolves to a known unit.
    #
    # @param op [Hash] The operation to potentially expand
    # @param current_unit [String] The identifier of the unit containing this operation
    # @param steps [Array<Hash>] Accumulator for step hashes
    # @param visited [Set<String>] Visited unit identifiers for cycle detection
    # @param depth [Integer] Current recursion depth
    # @param max_depth [Integer] Maximum recursion depth
    def expand_operation(op, current_unit, steps, visited, depth:, max_depth:)
      case op[:type]
      when :call, :async
        target = op[:target]
        return unless target

        # Check if the target is a known unit in the graph
        unit_id, = parse_identifier(current_unit)
        dep_ids = @graph.dependencies_of(unit_id)
        candidate = resolve_target(target, dep_ids)
        return unless candidate

        expand(candidate, steps, visited, depth: depth + 1, max_depth: max_depth)
      when :transaction
        (op[:nested] || []).each do |nested_op|
          expand_operation(nested_op, current_unit, steps, visited, depth: depth, max_depth: max_depth)
        end
      when :conditional
        ((op[:then_ops] || []) + (op[:else_ops] || [])).each do |branch_op|
          expand_operation(branch_op, current_unit, steps, visited, depth: depth, max_depth: max_depth)
        end
      end
    end

    # Resolve a call target to a unit identifier in the graph.
    def resolve_target(target, known_deps)
      # Direct match in dependencies
      return target if known_deps.include?(target)

      # Try as a class name match
      known_deps.find { |dep| dep == target || dep.end_with?("::#{target}") }
    end

    # Parse an identifier into [unit_id, method_name].
    # "PostsController#create" => ["PostsController", "create"]
    # "PostService" => ["PostService", nil]
    def parse_identifier(identifier)
      if identifier.include?('#')
        identifier.split('#', 2)
      else
        [identifier, nil]
      end
    end

    # Load an ExtractedUnit's data from its JSON file on disk.
    #
    # Uses the same filename convention as {Extractor#safe_filename}: colons
    # become double underscores, non-alphanumeric chars become underscores.
    # Searches across type subdirectories since the extractor writes to
    # `<output_dir>/<type>/<safe_filename>.json`.
    def load_unit(unit_id)
      filename = "#{unit_id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"

      Dir[File.join(@extracted_dir, '*', filename)].each do |path|
        return JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        next
      end

      nil
    end

    # Extract route information from controller metadata.
    def extract_route(entry_point)
      unit_id, method_name = parse_identifier(entry_point)
      unit_data = load_unit(unit_id)
      return nil unless unit_data

      metadata = unit_data[:metadata] || {}
      routes = metadata[:routes]
      return nil unless routes.is_a?(Array)

      # Find route matching the method name
      route = if method_name
                routes.find { |r| r[:action]&.to_s == method_name }
              else
                routes.first
              end

      return nil unless route

      {
        verb: route[:verb],
        path: route[:path]
      }
    end
  end
end
