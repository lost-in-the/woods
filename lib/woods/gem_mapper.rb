# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'time'

require_relative 'atomic_file'
require_relative 'coordination/pipeline_lock'
require_relative 'dependency_graph'
require_relative 'extracted_unit'
require_relative 'filename_utils'
require_relative 'generation'
require_relative 'graph_analyzer'
require_relative 'payload_store'
require_relative 'ruby_analyzer'

module Woods
  # Publishes a static, source-only index of the Woods implementation.
  class GemMapper
    include FilenameUtils

    SOURCE_GLOBS = %w[lib/woods.rb lib/woods/**/*.rb lib/tasks/**/*.rake exe/*].freeze
    TYPE_DIRECTORIES = {
      ruby_class: 'ruby_classes', ruby_module: 'ruby_modules',
      ruby_method: 'ruby_methods', ruby_file: 'ruby_files'
    }.freeze
    PROVENANCE = {
      mode: 'woods_static_ruby_source', runtime_fidelity: 'none', embeddings: 'absent',
      included: SOURCE_GLOBS, excluded: %w[spec docs .git tmp vendor]
    }.freeze

    def initialize(root:, output_dir:)
      @root = Pathname.new(root).expand_path
      @output_dir = Pathname.new(output_dir).expand_path
    end

    # Publishes one complete source snapshot, or skips when it is unchanged.
    def map!
      with_lock do
        snapshot = source_snapshot
        return { status: :skipped, generation: current_generation.number } if current_checksum == snapshot[:checksum]

        units = build_units(snapshot[:sources])
        graph = DependencyGraph.new
        units.each { |unit| graph.register(unit) }
        payload = PayloadStore.new(@output_dir).create(next_generation)
        write_payload(payload, units, graph, snapshot[:checksum])
        ensure_snapshot_unchanged!(snapshot[:checksum])

        marker = Generation.new(output_dir: @output_dir).bump!(
          reason: 'woods_static_source_map', payload: PayloadStore.name_for(next_generation)
        )
        PayloadStore.new(@output_dir).prune(keep: PayloadStore::DEFAULT_RETENTION, protect: marker.number)
        { status: :published, generation: marker.number, units: units.size }
      end
    end

    private

    def with_lock(&block)
      Coordination::PipelineLock.new(lock_dir: @output_dir.to_s, name: 'woods_self_map').with_lock(&block)
    end

    def source_files
      SOURCE_GLOBS.flat_map { |glob| Dir.glob(@root.join(glob).to_s) }
                  .select { |path| File.file?(path) }.uniq.sort
    end

    def source_snapshot
      sources = source_files.to_h { |path| [path, read_source(path)] }
      { sources: sources, checksum: checksum_for(sources) }
    end

    def checksum_for(sources)
      digest = Digest::SHA256.new
      sources.sort.each { |path, source| digest << relative_path(path) << "\0" << source << "\0" }
      digest.hexdigest
    end

    def read_source(path)
      source = File.read(path, encoding: Encoding::UTF_8)
      source.valid_encoding? ? source : source.scrub
    end

    def ensure_snapshot_unchanged!(checksum)
      return if source_snapshot[:checksum] == checksum

      raise Woods::ExtractionError, 'Woods source changed during self-map; refusing to publish a mixed snapshot'
    end

    def current_generation
      Generation.new(output_dir: @output_dir).current
    end

    def next_generation
      current_generation.number + 1
    end

    def current_checksum
      payload = Generation.new(output_dir: @output_dir).payload_dir(current_generation)
      manifest = payload.join('manifest.json')
      return nil unless manifest.file?

      JSON.parse(AtomicFile.read(manifest)).dig('provenance', 'source_checksum')
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def build_units(sources)
      analyzable = sources.select { |path, _| path.end_with?('.rb', '.rake') || executable?(path) }
      units = RubyAnalyzer.analyze(sources: analyzable)
      units.each { |unit| unit.file_path = relative_path(unit.file_path) }
      units.concat(file_units(sources))
      disambiguate!(units)
      resolve_dependents(units)
      units.sort_by { |unit| [unit.identifier, unit.type.to_s, unit.file_path] }
    end

    def executable?(path)
      path.start_with?(@root.join('exe').to_s + File::SEPARATOR)
    end

    def file_units(sources)
      sources.map do |path, source|
        relative = relative_path(path)
        unit = ExtractedUnit.new(type: :ruby_file, identifier: "file:#{relative}", file_path: relative)
        unit.source_code = source
        unit.metadata = { static_kind: 'ruby_file', executable: executable?(path) }
        unit
      end
    end

    def disambiguate!(units)
      units.group_by(&:identifier).each do |canonical, colliding|
        colliding.sort_by! { |unit| [unit.file_path, unit.type.to_s] }
        colliding.each_with_index do |unit, index|
          unit.metadata[:canonical_identifier] = canonical
          next if index.zero?

          unit.identifier = "#{canonical} [#{unit.file_path}]"
          unit.dependencies << { type: unit.type, target: canonical, via: :definition_of }
        end
      end
    end

    def resolve_dependents(units)
      by_identifier = units.group_by(&:identifier)
      units.each do |unit|
        unit.dependencies.each do |dependency|
          Array(by_identifier[dependency[:target]]).each do |target|
            target.dependents << { type: unit.type, identifier: unit.identifier }
          end
        end
      end
    end

    def write_payload(payload, units, graph, checksum)
      TYPE_DIRECTORIES.each { |type, directory| write_type(payload.join(directory), units.select { |unit| unit.type == type }) }
      write_graph(payload, graph)
      write_manifest(payload, units, graph, checksum)
      write_summary(payload, units, graph)
    end

    def write_type(directory, units)
      FileUtils.mkdir_p(directory)
      units.each { |unit| AtomicFile.write(directory.join(collision_safe_filename(unit.identifier)), JSON.pretty_generate(unit.to_h)) }
      index = units.map do |unit|
        { identifier: unit.identifier, file_path: unit.file_path, namespace: unit.namespace,
          estimated_tokens: unit.estimated_tokens, chunk_count: unit.chunks.size }
      end
      AtomicFile.write(directory.join('_index.json'), JSON.pretty_generate(index))
    end

    def write_graph(payload, graph)
      data = graph.to_h
      data[:pagerank] = graph.pagerank
      AtomicFile.write(payload.join('dependency_graph.json'), JSON.pretty_generate(data))
      AtomicFile.write(payload.join('graph_analysis.json'), JSON.pretty_generate(GraphAnalyzer.new(graph).analyze))
    end

    def write_manifest(payload, units, graph, checksum)
      counts = TYPE_DIRECTORIES.keys.to_h { |type| [TYPE_DIRECTORIES[type], units.count { |unit| unit.type == type }] }
      manifest = {
        extracted_at: Time.now.utc.iso8601, rails_version: nil, ruby_version: RUBY_VERSION,
        counts: counts, total_units: units.size, total_chunks: 0, git_sha: nil, git_branch: nil,
        provenance: PROVENANCE.merge(source_checksum: checksum), graph_nodes: graph.to_h.dig(:stats, :node_count),
        graph_edges: graph.to_h.dig(:stats, :edge_count)
      }
      AtomicFile.write(payload.join('manifest.json'), JSON.pretty_generate(manifest))
    end

    def write_summary(payload, units, graph)
      stats = graph.to_h.fetch(:stats)
      AtomicFile.write(payload.join('SUMMARY.md'), [
        '# Woods static Ruby source map', '', "Units: #{units.size}", "Graph nodes: #{stats[:node_count]}",
        "Graph edges: #{stats[:edge_count]}", 'Static source analysis only; not a Rails runtime extraction.'
      ].join("\n"))
    end

    def relative_path(path)
      Pathname.new(path).expand_path.relative_path_from(@root).to_s
    rescue ArgumentError
      raise Woods::ExtractionError, "Source path escapes gem root: #{path}"
    end
  end
end
