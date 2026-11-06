# frozen_string_literal: true

# Exact graph/analysis reuse for the opt-in client pilot.
require 'json'
require 'digest'
require 'woods/extractor'
module Woods
  module Experimental
    module IncrementalReuse
      module GraphReuse
        class Witness
          IMPLEMENTATIONS = %w[extractor.rb graph_analyzer.rb dependency_graph.rb
                               experimental/incremental_reuse.rb experimental/graph_state.rb
                               experimental/reuse_hooks.rb].freeze

          def self.capture(extractor, graph)
            { options: options, source: sources(extractor, graph),
              controller_resolution: missing_controllers(graph).map do |id|
                [id, extractor.send(:defined_controller?, id)]
              end,
              code: IMPLEMENTATIONS.map do |file|
                Digest::SHA256.file(File.join(IncrementalReuse::SOURCE_ROOT, file)).hexdigest
              end,
              constants: Woods::GraphAnalyzer.constants(false).sort.map do |name|
                [name, Woods::GraphAnalyzer.const_get(name)]
              end,
              root: File.realpath(Rails.root), ruby: RUBY_VERSION, rails: Rails.version }
          end

          def self.options
            config = Woods.configuration
            [config&.volatile_dependency_ratio || Woods::GraphAnalyzer::DEFAULT_VOLATILE_RATIO,
             config&.volatile_dependency_limit_per_target,
             config ? config.graph_cycle_limit : Woods::GraphAnalyzer::DEFAULT_CYCLE_LIMIT,
             config ? config.graph_cycle_max_length : Woods::GraphAnalyzer::DEFAULT_CYCLE_MAX_LENGTH]
          end

          def self.sources(extractor, graph)
            paths = []
            graph.each_node { |_id, node| paths << node[:file_path].to_s if node[:file_path] }
            paths.uniq.sort.map do |path|
              [File.expand_path(path, Rails.root.to_s), extractor.send(:application_source?, path)]
            end.uniq.sort
          end

          def self.missing_controllers(graph)
            controllers = graph.units_of_type(:route).filter_map do |id|
              next unless graph.node(id, type: :route)&.dig(:route_action)

              dispatch = graph.edge_records(id, type: :route).find { |edge| edge[:via].to_s == 'route_dispatch' }
              dispatch&.dig(:target)
            end
            controllers.uniq.sort.reject { |id| graph.node(id, type: :controller) }
          end

          def self.key(extractor, graph)
            Digest::SHA256.hexdigest(JSON.generate(capture(extractor, graph)))
          end
        end

        class Cache
          attr_reader :graph_sha, :witness, :graph_without_rank

          def initialize(graph_bytes:, analysis_bytes:, witness:)
            @graph_sha = Digest::SHA256.hexdigest(graph_bytes)
            parsed = JSON.parse(graph_bytes)
            parsed.delete('pagerank')
            @graph_without_rank = JSON.generate(parsed)
            @analysis_bytes = analysis_bytes
            raise 'cache analysis graph mismatch' unless JSON.parse(analysis_bytes)['graph_sha'] == @graph_sha

            @witness = witness
          end

          def valid_analysis?(sha, witness) = sha == @graph_sha && witness == @witness

          def analysis
            JSON.parse(@analysis_bytes, symbolize_names: true).except(:generated_at, :graph_sha)
          end
        end
      end
    end
  end
end
