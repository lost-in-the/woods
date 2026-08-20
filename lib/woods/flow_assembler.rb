# frozen_string_literal: true

require 'digest'
require 'json'
require 'set'
require_relative 'ast/parser'
require_relative 'ast/method_extractor'
require_relative 'flow_analysis/operation_extractor'
require_relative 'flow_document'

module Woods
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
  #   assembler = FlowAssembler.new(graph: graph, extracted_dir: "/tmp/woods")
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
      @resolved_targets = {}
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
    # A cycle is a re-encounter on the CURRENT recursion path (tracked in
    # +path+, popped on exit — the gray set of a DFS). A unit already
    # expanded via a sibling branch (a DAG diamond: two services calling
    # the same model) is plain dedup, not a cycle — it is skipped silently
    # rather than mislabeled with a cycle marker.
    #
    # @param identifier [String] Unit identifier (may include #method)
    # @param steps [Array<Hash>] Accumulator for step hashes
    # @param visited [Set<String>] Already-expanded unit identifiers (dedup)
    # @param depth [Integer] Current recursion depth
    # @param max_depth [Integer] Maximum recursion depth
    # @param path [Set<String>] Identifiers on the current recursion path
    # @param method_name [String, nil] The method the caller actually invoked
    #   (from the triggering operation's `op[:method]`), for callers that
    #   resolve to a bare unit id and so cannot encode it in +identifier+
    #   itself. `identifier`'s own `#method` suffix (entry points) wins when
    #   both are present.
    def expand(identifier, steps, visited, depth:, max_depth:, path: Set.new, method_name: nil)
      return if depth > max_depth

      # Parse identifier into unit name and optional method
      unit_id, parsed_method = parse_identifier(identifier)
      method_name = parsed_method || method_name

      if path.include?(unit_id)
        # Genuine cycle — the unit is an ancestor of itself on this path.
        steps << {
          unit: unit_id,
          type: 'cycle',
          operations: [{ type: :cycle, target: unit_id, line: nil }]
        }
        return
      end

      # Already expanded through another branch — dedup, not a cycle.
      return if visited.include?(unit_id)

      visited.add(unit_id)
      path.add(unit_id)

      begin
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
          expand_operation(op, identifier, steps, visited, depth: depth, max_depth: max_depth, path: path)
        end
      ensure
        # Pop on every exit (including the early returns above) — a unit
        # left on the path would make sibling branches report false cycles.
        path.delete(unit_id)
      end
    end

    # Extract operations from source code for a specific method — or, when no
    # method is named or the unit does not define one by that name, from the
    # entire source.
    #
    # A named method that isn't found falls back to the whole unit rather
    # than yielding no operations: {#expand_operation} now threads the
    # calling operation's `op[:method]` through, and that method need not be
    # one the callee actually defines locally (inherited, dynamically
    # defined, or metaprogrammed) — losing the trace entirely would be worse
    # than over-including it.
    def extract_operations(source_code, method_name, metadata, unit_type)
      operations = []

      # For controllers, prepend before_action callbacks
      prepend_callbacks(operations, metadata, method_name) if unit_type == 'controller'

      scope_node = method_name && @method_extractor.extract_method(source_code, method_name)
      scope_node ||= @parser.parse(source_code)
      operations.concat(@operation_extractor.extract(scope_node))

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
    # `op[:method]` is threaded into the recursive {#expand} call so the
    # callee is scoped to the method actually invoked, not its whole source.
    # When {#resolve_target} answers with an ambiguity marker (several
    # namespaces share the target's short name) this does not recurse at
    # all — it mutates +op+ in place with `:ambiguous_candidates` so the
    # unresolved call is still visible in the flow output, naming every
    # candidate instead of silently expanding whichever one the graph's
    # suffix index happened to pick.
    #
    # @param op [Hash] The operation to potentially expand
    # @param current_unit [String] The identifier of the unit containing this operation
    # @param steps [Array<Hash>] Accumulator for step hashes
    # @param visited [Set<String>] Visited unit identifiers for cycle detection
    # @param depth [Integer] Current recursion depth
    # @param max_depth [Integer] Maximum recursion depth
    def expand_operation(op, current_unit, steps, visited, depth:, max_depth:, path: Set.new)
      case op[:type]
      when :call, :async
        target = op[:target]
        return unless target

        resolution = resolve_target(target)
        return unless resolution

        if resolution.is_a?(Hash)
          # Several namespaces share this short name (Tier 1 suffix match) —
          # record which ones rather than silently expanding whichever the
          # graph's deterministic-but-arbitrary suffix index picked.
          op[:ambiguous_candidates] = resolution[:candidates]
          return
        end

        expand(
          resolution, steps, visited,
          depth: depth + 1, max_depth: max_depth, path: path, method_name: op[:method]
        )
      when :transaction
        (op[:nested] || []).each do |nested_op|
          expand_operation(nested_op, current_unit, steps, visited, depth: depth, max_depth: max_depth, path: path)
        end
      when :conditional
        ((op[:then_ops] || []) + (op[:else_ops] || [])).each do |branch_op|
          expand_operation(branch_op, current_unit, steps, visited, depth: depth, max_depth: max_depth, path: path)
        end
      end
    end

    # Resolve a call target to a unit identifier using graph-wide lookup.
    #
    # Uses node existence checks rather than dependency edges, because
    # dependency edges are structural (associations, includes) and don't
    # represent actual call relationships in execution flows.
    #
    # Tier 1: Graph-wide lookup — checks if the node exists anywhere in the graph,
    #          including suffix matching for unqualified class names.
    # Tier 2: Disk fallback — attempts to load the unit JSON from disk, covering
    #          units that exist in the index but were not loaded into the graph.
    #
    # @param target [String] The call target name to resolve
    # @return [String, nil] The resolved unit identifier, or nil if not found
    # Memoized per assembler instance, and negative results are cached too
    # (`nil` is a real answer — most call targets are not units). Resolution
    # used to run a linear suffix scan over every graph node *and*, on a miss,
    # a set of disk globs, once per operation encountered. A flow touching a
    # few hundred operations on a host with tens of thousands of nodes paid
    # that every time, including for the same target repeatedly.
    def resolve_target(target)
      return @resolved_targets[target] if @resolved_targets.key?(target)

      @resolved_targets[target] = compute_resolved_target(target)
    end

    # @return [String, Hash, nil] a resolved unit identifier; a
    #   `{ ambiguous: true, candidates: }` marker when several namespaces
    #   share +target+'s short name; or nil when nothing resolves
    def compute_resolved_target(target)
      # Tier 1: Graph-wide lookup
      return target if @graph.node_exists?(target)

      suffix_matches = @graph.find_all_by_suffix(target)
      return suffix_matches.first if suffix_matches.size == 1
      return { ambiguous: true, candidates: suffix_matches } if suffix_matches.size > 1

      # Tier 2: Disk fallback (unit JSON exists but isn't in the graph)
      unit_data = load_unit(target)
      return target if unit_data

      nil
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
    # Uses {Extractor#collision_safe_filename} convention (with SHA256 digest suffix).
    # Falls back to legacy {Extractor#safe_filename} for older indexes.
    # Searches across type subdirectories since the extractor writes to
    # `<output_dir>/<type>/<filename>.json`.
    def load_unit(unit_id)
      base = unit_id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      digest = Digest::SHA256.hexdigest(unit_id)[0, 8]
      filenames = [
        "#{base}_#{digest}.json",
        "#{base}.json"
      ]

      filenames.each do |filename|
        Dir[File.join(@extracted_dir, '*', filename)].each do |path|
          # Force UTF-8: the extractor writes the routes-comment header in
          # source_code using Unicode box-drawing characters; reading under
          # the platform default (US-ASCII on some CIs) raises
          # InvalidByteSequenceError before JSON parsing.
          return JSON.parse(File.read(path, encoding: 'UTF-8'), symbolize_names: true)
        rescue JSON::ParserError
          next
        end
      end

      nil
    end

    # Extract route information from controller metadata.
    #
    # Handles two on-disk shapes:
    # - Hash keyed by action (what ControllerExtractor writes):
    #     { "create" => [{ verb:, path:, ... }, ...] }
    # - Array of route hashes (older / test fixture shape):
    #     [{ action:, verb:, path: }, ...]
    def extract_route(entry_point)
      unit_id, method_name = parse_identifier(entry_point)
      unit_data = load_unit(unit_id)
      return nil unless unit_data

      metadata = unit_data[:metadata] || {}
      route = resolve_route_entry(metadata[:routes], method_name)
      return nil unless route

      { verb: route[:verb], path: route[:path] }
    end

    def resolve_route_entry(routes, method_name)
      case routes
      when Hash
        action_routes = method_name ? routes[method_name.to_s] || routes[method_name.to_sym] : routes.values.first
        Array(action_routes).first
      when Array
        method_name ? routes.find { |r| r[:action]&.to_s == method_name } : routes.first
      end
    end
  end
end
