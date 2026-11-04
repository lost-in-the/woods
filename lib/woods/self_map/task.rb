# frozen_string_literal: true

require 'pathname'
require_relative '../gem_mapper'
require_relative '../gem_map_affected_specs'
require_relative '../published_index'
require_relative 'snapshot'
require_relative 'inventory'
require_relative 'impact'
require_relative 'guide'
require_relative 'publication'

module Woods
  module SelfMap
    # Woods-only orchestration; refresh, pin, render, verify and publish.
    class Task
      RENDERER_VERSION = 1

      def self.from_environment(root)
        root = Pathname.new(root)
        raise ArgumentError, 'Self context tasks require a Woods source checkout' unless root.join('AGENTS.md').file?

        new(root: root, index_dir: ENV.fetch('WOODS_SELF_MAP_OUTPUT', root.join('tmp/woods_self_map')),
            output_dir: ENV.fetch('WOODS_SELF_CONTEXT_OUTPUT', root.join('tmp/woods_agent')))
      end

      def initialize(root:, index_dir:, output_dir:)
        @root = Pathname.new(root).expand_path
        @index_dir = index_dir
        @output_dir = output_dir
        @mapper = GemMapper.new(root: @root, output_dir: @index_dir)
      end

      def docs
        with_current do |snapshot|
          inventory = Inventory.new(@root, snapshot).to_h
          files = Guide.new(snapshot, inventory, root: @root).files
          publish('guide', snapshot, files)
        end
      end

      def impact(paths:, base_generation: nil, options: {})
        paths = normalize_paths(paths)
        raise ArgumentError, 'Unsupported self-impact options' unless (options.keys - %i[depth max_nodes
                                                                                         max_edges]).empty?

        query = Impact.new(paths, options: options)
        with_baseline(base_generation) do |baseline|
          with_current do |current|
            report = query.call(current, baseline: baseline)
            report['inputs'] = Inventory.new(@root, current).to_h
            files = { 'impact.json' => JSON.pretty_generate(report), 'impact.md' => Markdown.impact(report, @root) }
            publish('impact', current, files)
          end
        end
      end

      private

      def normalize_paths(paths)
        raise ArgumentError, 'Paths must be an array' unless paths.is_a?(Array)

        paths.map { |path| normalize_path(path) }.uniq.sort
      end

      def normalize_path(path)
        raise ArgumentError, 'Paths must be nonempty relative strings' unless path.is_a?(String) && !path.empty?

        normalized = Pathname.new(path).cleanpath
        if normalized.absolute? || normalized.to_s == '..' || normalized.to_s.start_with?('../')
          raise ArgumentError, 'Paths must remain inside the Woods checkout'
        end

        normalized.to_s
      end

      def with_current
        @mapper.map!
        PublishedIndex.open(@index_dir) { |reader| yield Snapshot.new(reader) }
      end

      def with_baseline(generation)
        return yield nil if generation.nil?
        unless generation.to_s.match?(/\A[1-9]\d*\z/)
          raise ArgumentError, 'Baseline must be a positive retained generation number'
        end

        reader = baseline_reader(generation.to_i)
        begin
          yield Snapshot.new(reader)
        ensure
          reader.close
        end
      end

      def baseline_reader(generation)
        PublishedIndex.new(@index_dir, generation: generation)
      rescue ArgumentError => e
        raise IOError, "Requested self-map baseline is unavailable: #{e.message}"
      end

      def publish(kind, snapshot, files)
        manifest = snapshot.provenance.merge('schema_version' => 1, 'renderer_version' => RENDERER_VERSION,
                                             'source_root' => @root.to_s, 'freshness' => 'matched_before_publication')
        files = files.merge('manifest.json' => JSON.pretty_generate(manifest))
        Publication.new(@output_dir).publish(kind, files) do
          unless @mapper.source_checksum == snapshot.provenance['source_checksum']
            raise IOError, 'Woods covered sources changed during context rendering; rerun the task'
          end
        end
      end
    end
  end
end
