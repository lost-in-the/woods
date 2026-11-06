# frozen_string_literal: true

module Woods
  module Experimental
    module IncrementalReuse
      module ExtractorHook
        def with_parse_cache(&block)
          IncrementalReuse.run(self) { super(&block) }
        end

        def refresh(*keys)
          IncrementalReuse.run(self) { super }
        end

        private

        def reuse_context
          context = IncrementalReuse.current
          context if context&.extractor.equal?(self)
        end

        def prepare_incremental_run(...)
          @reuse_graph_unchanged = false
          reuse_context.incremental = true if reuse_context
          super
        end

        def write_dependency_graph
          context = reuse_context
          return super unless context&.graph? && context.incremental && context.session.graph

          data = JSON.generate(@dependency_graph.to_h)
          bytes = AtomicFile.read(payload_dir.join('dependency_graph.json'))
          previous = JSON.parse(bytes)
          previous.delete('pagerank')
          if data == JSON.generate(previous)
            @graph_sha = Digest::SHA256.hexdigest(bytes)
            @reuse_graph_unchanged = true
            context.session.counts[:graph_reused] += 1
          else
            context.session.counts[:graph_misses] += 1
            super
          end
        end

        def write_incremental_graph_analysis
          context = reuse_context
          cache = context&.session&.graph
          if reusable_analysis?(context, cache)
            @graph_analysis = cache.analysis
            context.session.counts[:analysis_reused] += 1
            write_graph_analysis
          else
            context.session.counts[:analysis_misses] += 1 if context&.graph?
            super
          end
        end

        def reusable_analysis?(context, cache)
          return false unless context&.graph? && @reuse_graph_unchanged && cache

          cache.valid_analysis?(graph_sha, GraphReuse::Witness.key(self, @dependency_graph))
        end

        def write_graph_analysis
          result = super
          context = reuse_context
          return result unless context&.graph?

          begin
            context.pending_graph = GraphReuse::Cache.new(
              graph_bytes: AtomicFile.read(payload_dir.join('dependency_graph.json')),
              analysis_bytes: AtomicFile.read(payload_dir.join('graph_analysis.json')),
              witness: GraphReuse::Witness.key(self, @dependency_graph)
            )
          rescue StandardError
            context.pending_graph = nil
            context.session.counts[:cache_errors] += 1
          end
          result
        end

        def publish_generation(reason)
          marker = super
          context = reuse_context
          context.published_marker = [marker.number, marker.token, marker.payload] if marker && context
          marker
        end
      end
    end
  end
end
