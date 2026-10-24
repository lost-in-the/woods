# frozen_string_literal: true

module Woods
  module Diagrams
    # The reads every builder shares, over one reader pinned to one
    # generation: units by typed identity, the raw dependency graph with its
    # variants, the graph analysis and the flow assembler. Nothing here
    # resolves a path the reader did not give it.
    class Source
      # @param reader [Woods::MCP::IndexReader]
      # @param index_dir [String, Pathname, nil] the index root (impact reports open their own endpoints)
      def initialize(reader, index_dir: nil)
        @reader = reader
        @index_dir = index_dir
        @units = {}
      end

      # @return [String, Pathname, nil]
      attr_reader :index_dir

      # @return [Woods::MCP::IndexReader]
      attr_reader :reader

      # @return [Array] what keys this generation in the cache
      def cache_identity
        @cache_identity ||= @reader.generation_identity
      end

      # @return [Integer] the published generation number, 0 for a flat index
      def generation
        cache_identity.first.to_i
      end

      # @param identifier [String]
      # @param type [String, nil]
      # @return [Hash, nil] the published unit
      def unit(identifier, type: nil)
        @units.fetch([identifier, type]) { @units[[identifier, type]] = @reader.find_unit(identifier, type: type) }
      rescue ArgumentError
        @units[[identifier, type]] = nil
      end

      # @return [Hash] the raw dependency graph: nodes, edges, reverse_via, pagerank, variants
      def graph
        @graph ||= @reader.raw_graph_data || {}
      end

      # @return [Hash] graph_analysis.json, empty when absent or unreadable
      def graph_analysis
        @graph_analysis ||= @reader.graph_analysis || {}
      rescue StandardError
        @graph_analysis = {}
      end

      # The graph node of an identifier: the one of +type+ when given (a
      # primary node or a variant), else the primary node.
      #
      # @param identifier [String]
      # @param type [String, nil]
      # @return [Hash, nil]
      def graph_node(identifier, type: nil)
        nodes = Array(nodes_by_identifier[identifier])
        type ? nodes.find { |node| node['type'].to_s == type.to_s } : nodes.first
      end

      # @param identifier [String]
      # @return [String, nil] the primary node's type
      def type_of(identifier)
        graph_node(identifier)&.dig('type')
      end

      # @return [Hash{String => String}] model identifier => the table its graph node names
      def model_tables
        @model_tables ||= Hash(graph['nodes']).each_with_object({}) do |(identifier, node), tables|
          tables[identifier] = node['table'] if node['type'] == 'model' && node['table']
        end
      end

      # @param unit [Hash] a published model unit
      # @return [Hash{String => Array<String>}] each inlined concern => the instance methods it defines
      def concern_methods(unit)
        Array(unit.dig('metadata', 'inlined_concerns')).to_h do |name|
          concern = unit(name, type: 'concern')
          [name, Array(concern&.dig('metadata', 'instance_methods')).map(&:to_s)]
        end
      end

      # @return [Woods::FlowAssembler] over this generation's published units
      def flow_assembler
        @flow_assembler ||= begin
          require_relative '../flow_assembler'
          Woods::FlowAssembler.new(graph: @reader.dependency_graph, extracted_dir: @reader.payload_dir.to_s)
        end
      end

      private

      def nodes_by_identifier
        @nodes_by_identifier ||= begin
          nodes = Hash(graph['nodes']).transform_values { |node| [node] }
          Array(graph['variants']).grep(Hash).each do |record|
            next unless record['identifier']

            (nodes[record['identifier']] ||= []) << record
          end
          nodes
        end
      end
    end
  end
end
