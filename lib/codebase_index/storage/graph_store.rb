# frozen_string_literal: true

require_relative '../dependency_graph'

module CodebaseIndex
  module Storage
    # GraphStore provides an interface for querying code unit relationships.
    #
    # All graph store adapters must include the {Interface} module and implement
    # its methods. The {Memory} adapter wraps the existing {DependencyGraph}.
    #
    # @example Using the memory adapter
    #   store = CodebaseIndex::Storage::GraphStore::Memory.new
    #   store.register(unit)
    #   store.dependencies_of("User")
    #
    module GraphStore
      # Interface that all graph store adapters must implement.
      module Interface
        # Get direct dependencies of a unit.
        #
        # @param identifier [String] Unit identifier
        # @return [Array<String>] List of dependency identifiers
        # @raise [NotImplementedError] if not implemented by adapter
        def dependencies_of(identifier)
          raise NotImplementedError
        end

        # Get direct dependents of a unit (reverse dependencies).
        #
        # @param identifier [String] Unit identifier
        # @return [Array<String>] List of dependent identifiers
        # @raise [NotImplementedError] if not implemented by adapter
        def dependents_of(identifier)
          raise NotImplementedError
        end

        # Find all units transitively affected by changes to the given files.
        #
        # @param changed_files [Array<String>] List of changed file paths
        # @param max_depth [Integer, nil] Maximum traversal depth (nil for unlimited)
        # @return [Array<String>] List of affected unit identifiers
        # @raise [NotImplementedError] if not implemented by adapter
        def affected_by(changed_files, max_depth: nil)
          raise NotImplementedError
        end

        # Get all units of a specific type.
        #
        # @param type [Symbol] Unit type (:model, :controller, etc.)
        # @return [Array<String>] List of unit identifiers
        # @raise [NotImplementedError] if not implemented by adapter
        def by_type(type)
          raise NotImplementedError
        end

        # Compute PageRank importance scores for all units.
        #
        # @param damping [Float] Damping factor (default: 0.85)
        # @param iterations [Integer] Number of iterations (default: 20)
        # @return [Hash<String, Float>] Identifier => PageRank score
        # @raise [NotImplementedError] if not implemented by adapter
        def pagerank(damping: 0.85, iterations: 20)
          raise NotImplementedError
        end
      end

      # In-memory graph store wrapping the existing DependencyGraph.
      #
      # Delegates all operations to {CodebaseIndex::DependencyGraph}, providing
      # a consistent storage interface.
      #
      # @example
      #   store = Memory.new
      #   store.register(user_unit)
      #   store.dependencies_of("User")  # => ["Organization"]
      #
      class Memory
        include Interface

        # @param graph [DependencyGraph, nil] Existing graph to wrap, or nil to create a new one
        def initialize(graph = nil)
          @graph = graph || DependencyGraph.new
        end

        # Register a unit in the graph.
        #
        # @param unit [ExtractedUnit] The unit to register
        def register(unit)
          @graph.register(unit)
        end

        # @see Interface#dependencies_of
        def dependencies_of(identifier)
          @graph.dependencies_of(identifier)
        end

        # @see Interface#dependents_of
        def dependents_of(identifier)
          @graph.dependents_of(identifier)
        end

        # @see Interface#affected_by
        def affected_by(changed_files, max_depth: nil)
          @graph.affected_by(changed_files, max_depth: max_depth)
        end

        # @see Interface#by_type
        def by_type(type)
          @graph.units_of_type(type)
        end

        # @see Interface#pagerank
        def pagerank(damping: 0.85, iterations: 20)
          @graph.pagerank(damping: damping, iterations: iterations)
        end
      end
    end
  end
end
