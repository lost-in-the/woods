# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'time'
require 'prism'

require_relative 'atomic_file'
require_relative 'version'
require_relative 'coordination/pipeline_lock'
require_relative 'coordination/lock_heartbeat'
require_relative 'publication_seam'
require_relative 'dependency_graph'
require_relative 'extracted_unit'
require_relative 'gem_map_qualifier'
require_relative 'gem_map_specs'
require_relative 'filename_utils'
require_relative 'generation'
require_relative 'graph_analyzer'
require_relative 'payload_store'
require_relative 'ruby_analyzer'

module Woods
  # The self-map's writer lock and publish step.
  #
  # `bin/woods-self-mcp` refreshes the map in the background, so two writers
  # of one map are ordinary. Each stages privately and publishes only inside
  # {Coordination::PipelineLock#fenced}, the same contract as the application
  # pipeline; the heartbeat keeps a long map from looking abandoned.
  class GemMapPublication
    LOCK_NAME = 'woods_self_map'

    def initialize(output_dir)
      @output_dir = Pathname.new(output_dir)
      @payloads = PayloadStore.new(@output_dir)
    end

    # @yieldparam publication [GemMapPublication] holding the lock
    def with_lock
      @lock = Coordination::PipelineLock.new(lock_dir: @output_dir.to_s, name: LOCK_NAME)
      unless @lock.acquire
        raise Coordination::LockError,
              "Cannot acquire lock '#{LOCK_NAME}' — another process is running"
      end

      begin
        Coordination::LockHeartbeat.run(@lock) { yield self }
      ensure
        @lock.release
      end
    end

    # Stage, let the caller write, flush, then promote, publish and prune
    # inside the fence. The stage is removed on every path that does not
    # promote it.
    #
    # @yieldparam stage [Pathname] the private stage to write into
    # @return [Generation::Marker]
    # @raise [Coordination::LockLostError] when the lock was taken over
    def publish
      number = current_number + 1
      stage = @payloads.create_stage(number, @lock.token)
      PublicationSeam.reach(:staged, @output_dir)
      yield stage
      # The publisher writes every file without its own flush; one flush of
      # the payload tree makes them all durable before the pointer moves,
      # the same contract the app pipeline keeps (see Extractor#sync_payload).
      AtomicFile.sync_directory_tree(stage)
      PublicationSeam.reach(:before_promotion, @output_dir)
      @lock.fenced { promote_and_publish(stage, number) }
    ensure
      @payloads.discard_stage(stage) if stage
    end

    private

    def current_number
      Generation.new(output_dir: @output_dir).current.number
    end

    def promote_and_publish(stage, number)
      unless current_number + 1 == number
        raise Woods::ExtractionError,
              "self-map generation moved to #{current_number} during publication (expected #{number - 1})"
      end

      @payloads.promote(stage, number)
      marker = Generation.new(output_dir: @output_dir).bump!(
        reason: 'woods_static_source_map', payload: PayloadStore.name_for(number)
      )
      PublicationSeam.reach(:marker_published, @output_dir)
      @payloads.prune(keep: PayloadStore::DEFAULT_RETENTION, protect: marker.number)
      marker
    end
  end

  # Publishes a static, source-only index of the Woods implementation.
  class GemMapper
    # Name of the self-map's writer lock (`woods_self_map.lock`).
    LOCK_NAME = GemMapPublication::LOCK_NAME

    include FilenameUtils

    ANALYSIS_VERSION = 2
    SOURCE_GLOBS = %w[lib/woods.rb lib/woods/**/*.rb lib/tasks/**/*.rake exe/*].freeze
    TYPE_DIRECTORIES = {
      ruby_class: 'ruby_classes', ruby_module: 'ruby_modules',
      ruby_method: 'ruby_methods', ruby_file: 'ruby_files'
    }.freeze
    PROVENANCE = {
      mode: 'woods_static_ruby_source', runtime_fidelity: 'none', embeddings: 'absent',
      included: SOURCE_GLOBS, references_only: GemMapSpecs::GLOBS, excluded: %w[docs .git tmp vendor]
    }.freeze

    def initialize(root:, output_dir:)
      @root = Pathname.new(root).expand_path
      @output_dir = Pathname.new(output_dir).expand_path
    end

    # Publishes one complete source snapshot, or skips when it is unchanged.
    def map!
      Woods::ParseCache.with { GemMapPublication.new(@output_dir).with_lock { |publication| map_locked(publication) } }
    end

    # Current covered-source identity, including the analyzer runtime.
    def source_checksum
      source_snapshot[:checksum]
    end

    private

    def map_locked(publication)
      snapshot = source_snapshot
      return { status: :skipped, generation: current_generation.number } if current_checksum == snapshot[:checksum]

      source = GemMapSource.new(root: @root)
      units, graph = source.build(snapshot[:sources])
      marker = publication.publish do |stage|
        GemMapPublisher.new(payload: stage, units: units, graph: graph, checksum: snapshot[:checksum],
                            health: source.health).write
        ensure_snapshot_unchanged!(snapshot[:checksum])
      end
      { status: :published, generation: marker.number, units: units.size }
    end

    def source_files
      (SOURCE_GLOBS + GemMapSpecs::GLOBS).flat_map { |glob| Dir.glob(@root.join(glob).to_s) }
                                         .select { |path| File.file?(path) }.uniq.sort
    end

    def source_snapshot
      sources = source_files.to_h { |path| [path, read_source(path)] }
      { sources: sources, checksum: checksum_for(sources) }
    end

    def checksum_for(sources)
      digest = Digest::SHA256.new
      digest << [ANALYSIS_VERSION, RUBY_ENGINE, RUBY_VERSION, Prism::VERSION].join(':') << "\0"
      sources.sort.each { |path, source| digest << relative_path(path) << "\0" << source << "\0" }
      digest.hexdigest
    end

    def read_source(path)
      source = File.read(path, encoding: Encoding::UTF_8)
      unless source.valid_encoding?
        raise Woods::ExtractionError,
              "Invalid UTF-8 in Woods source: #{relative_path(path)}"
      end

      source
    end

    def ensure_snapshot_unchanged!(checksum)
      return if source_snapshot[:checksum] == checksum

      raise Woods::ExtractionError, 'Woods source changed during self-map; refusing to publish a mixed snapshot'
    end

    def current_generation
      Generation.new(output_dir: @output_dir).current
    end

    def current_checksum
      payload = Generation.new(output_dir: @output_dir).payload_dir(current_generation)
      manifest = payload.join('manifest.json')
      return nil unless manifest.file?

      JSON.parse(AtomicFile.read(manifest)).dig('provenance', 'source_checksum')
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def relative_path(path)
      Pathname.new(path).expand_path.relative_path_from(@root).to_s
    rescue ArgumentError
      raise Woods::ExtractionError, "Source path escapes gem root: #{path}"
    end
  end

  # Turns a pre-read Woods source snapshot into typed static analysis units.
  class GemMapSource
    def initialize(root:)
      @root = root
    end

    attr_reader :health

    def build(sources)
      @diagnostics = []
      units = build_units(sources)
      @health = build_health(sources)
      graph = DependencyGraph.new
      units.each { |unit| graph.register(unit) }
      [units, graph]
    end

    private

    def build_units(sources)
      relative = sources.transform_keys { |path| relative_path(path) }
      specs = relative.select { |path, _| GemMapSpecs.spec?(path) }
      units = source_units(sources.reject { |path, _| specs.key?(relative_path(path)) })
      units.concat(spec_units(specs, relative.keys))
      GemMapQualifier.new(units).qualify!
      resolve_dependents(units)
      units.sort_by { |unit| [unit.identifier, unit.type.to_s, unit.file_path] }
    end

    def build_health(sources)
      failures = @diagnostics.map { |item| item.transform_keys(&:to_s) }.sort_by { |item| item['path'] }
      failed = failures.map { |item| item['path'] }
      files = sources.sort.map { |path, source| file_health(path, source, failed) }
      { schema_version: 1, analysis_version: GemMapper::ANALYSIS_VERSION,
        parser: Prism::VERSION, files: files, parse_failures: failures }
    end

    def file_health(path, source, failed)
      relative = relative_path(path)
      mode = GemMapSpecs.spec?(relative) ? 'reference_only' : 'parsed'
      mode = 'parse_failed' if failed.include?(relative)
      { path: relative, mode: mode, source_hash: Digest::SHA256.hexdigest(source) }
    end

    def spec_units(specs, paths)
      library = paths.select { |path| path.start_with?('lib/') && !specs.key?(path) }
      GemMapSpecs.new(library: library, paths: paths, diagnostics: @diagnostics).units(specs)
    end

    def source_units(sources)
      analyzable = sources.select { |path, _| path.end_with?('.rb', '.rake') || executable?(path) }
      diagnostics = []
      units = RubyAnalyzer.analyze(sources: analyzable, diagnostics: diagnostics)
      @diagnostics.concat(diagnostics.map { |item| item.merge(path: relative_path(item[:path])) })
      units.each { |unit| unit.file_path = relative_path(unit.file_path) }
      units.concat(file_units(sources))
      disambiguate!(units)
      units
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
        unit.dependencies = top_level_references(source) if script?(path)
        unit
      end
    end

    # Rake tasks and executables run their code at the top level, outside any
    # class or method, so no other unit records what they call.
    def script?(path)
      path.end_with?('.rake') || executable?(path)
    end

    # Constants a script calls methods on, as written. Top-level code sees
    # only absolute names, which is how {#qualify_dependencies} resolves a
    # unit without scopes.
    def top_level_references(source)
      calls = Ast::CallSiteExtractor.new.extract(Ast::Parser.new.parse(source))
      receivers = calls.filter_map { |call| call[:receiver] if call[:receiver]&.match?(/\A(?:::)?[A-Z]/) }
      receivers.uniq.map { |target| { type: :ruby_class, target: target, via: :method_call } }
    rescue Woods::ExtractionError
      []
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

    def relative_path(path)
      Pathname.new(path).expand_path.relative_path_from(@root).to_s
    rescue ArgumentError
      raise Woods::ExtractionError, "Source path escapes gem root: #{path}"
    end
  end

  # Writes a complete source-map payload before GemMapper atomically publishes it.
  class GemMapPublisher
    include FilenameUtils

    def initialize(payload:, units:, graph:, checksum:, health:)
      @payload = payload
      @units = units
      @graph = graph
      @checksum = checksum
      @health = health
    end

    def write
      GemMapper::TYPE_DIRECTORIES.each do |type, directory|
        write_type(@payload.join(directory), @units.select { |unit| unit.type == type })
      end
      write_graph
      write_manifest
      write_summary
    end

    private

    # Every payload file is written without its own fsync; {GemMapper#map!}
    # flushes the whole tree once before it publishes the pointer. Per-file
    # fsyncs were the largest single cost of a first self-map build
    # (~10,000 files, ~5.5s of a 14.5s build).
    def write_file(path, content)
      AtomicFile.write(path, content, durable: false)
    end

    def write_type(directory, units)
      FileUtils.mkdir_p(directory)
      units.each do |unit|
        write_file(directory.join(collision_safe_filename(unit.identifier)), JSON.pretty_generate(unit.to_h))
      end
      index = units.map { |unit| index_entry(unit) }
      write_file(directory.join('_index.json'), JSON.pretty_generate(index))
    end

    def index_entry(unit)
      { identifier: unit.identifier, type: unit.type.to_s, file_path: unit.file_path, namespace: unit.namespace,
        estimated_tokens: unit.estimated_tokens, chunk_count: unit.chunks.size,
        canonical_identifier: unit.metadata[:canonical_identifier], definition: own_definition?(unit) }
    end

    def own_definition?(unit)
      unit.type == :ruby_class || (unit.type == :ruby_module &&
        (unit.metadata[:method_count].to_i.positive? ||
         %i[constants includes extends].any? { |key| Array(unit.metadata[key]).any? }))
    end

    def write_graph
      data = @graph.to_h
      data[:pagerank] = @graph.pagerank
      write_file(@payload.join('dependency_graph.json'), JSON.pretty_generate(data))
      write_file(@payload.join('graph_analysis.json'), JSON.pretty_generate(GraphAnalyzer.new(@graph).analyze))
    end

    def write_manifest
      counts = GemMapper::TYPE_DIRECTORIES.keys.to_h do |type|
        [GemMapper::TYPE_DIRECTORIES[type], @units.count { |unit| unit.type == type }]
      end
      stats = @graph.to_h.fetch(:stats)
      manifest = {
        extracted_at: Time.now.utc.iso8601, rails_version: nil, ruby_version: RUBY_VERSION,
        woods_version: Woods::VERSION,
        counts: counts, total_units: @units.size, total_chunks: 0, git_sha: nil, git_branch: nil,
        provenance: GemMapper::PROVENANCE.merge(source_checksum: @checksum), self_map: @health,
        graph_nodes: stats[:node_count], graph_edges: stats[:edge_count]
      }
      write_file(@payload.join('manifest.json'), JSON.pretty_generate(manifest))
    end

    def write_summary
      stats = @graph.to_h.fetch(:stats)
      write_file(@payload.join('SUMMARY.md'), [
        '# Woods static Ruby source map', '', "Units: #{@units.size}", "Graph nodes: #{stats[:node_count]}",
        "Graph edges: #{stats[:edge_count]}", 'Static source analysis only; not a Rails runtime extraction.'
      ].join("\n"))
    end
  end
end
