# frozen_string_literal: true

# lib/tasks/codebase_index.rake
#
# Rake tasks for codebase indexing.
# These can be run manually or integrated into CI pipelines.
#
# Usage:
#   bundle exec rake codebase_index:extract          # Full extraction
#   bundle exec rake codebase_index:incremental      # Changed files only
#   bundle exec rake codebase_index:extract_framework # Rails/gem sources only
#   bundle exec rake codebase_index:validate          # Validate index integrity
#   bundle exec rake codebase_index:stats             # Show index statistics
#   bundle exec rake codebase_index:clean             # Remove index
#   bundle exec rake codebase_index:self_analyze      # Analyze gem's own source
#   bundle exec rake codebase_index:flow[EntryPoint]  # Generate execution flow

namespace :codebase_index do
  desc 'Full extraction of codebase for indexing'
  task extract: :environment do
    require 'codebase_index/extractor'

    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index'))

    puts 'Starting full codebase extraction...'
    puts "Output directory: #{output_dir}"
    puts

    extractor = CodebaseIndex::Extractor.new(output_dir: output_dir)
    results = extractor.extract_all

    puts
    puts 'Extraction complete!'
    puts '=' * 50
    results.each do |type, units|
      puts "  #{type.to_s.ljust(15)}: #{units.size} units"
    end
    puts '=' * 50
    puts "  Total: #{results.values.sum(&:size)} units"
    puts
    puts "Output written to: #{output_dir}"
  end

  desc 'Incremental extraction based on git changes'
  task incremental: :environment do
    require 'codebase_index/extractor'

    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index'))

    # Determine changed files from CI environment or git
    require 'open3'

    changed_files = if ENV['CHANGED_FILES']
                      # Explicit list from CI
                      ENV['CHANGED_FILES'].split(',').map(&:strip)
                    elsif ENV['CI_COMMIT_BEFORE_SHA']
                      # GitLab CI
                      output, = Open3.capture2('git', 'diff', '--name-only',
                                               "#{ENV['CI_COMMIT_BEFORE_SHA']}..#{ENV.fetch('CI_COMMIT_SHA', nil)}")
                      output.lines.map(&:strip)
                    elsif ENV['GITHUB_BASE_REF']
                      # GitHub Actions PR
                      output, = Open3.capture2('git', 'diff', '--name-only',
                                               "origin/#{ENV['GITHUB_BASE_REF']}...HEAD")
                      output.lines.map(&:strip)
                    else
                      # Default: changes since last commit
                      output, = Open3.capture2('git', 'diff', '--name-only', 'HEAD~1')
                      output.lines.map(&:strip)
                    end

    # Filter to relevant files
    relevant_patterns = [
      %r{^app/models/},
      %r{^app/controllers/},
      %r{^app/services/},
      %r{^app/components/},
      %r{^app/views/components/},
      %r{^app/views/.*\.rb$},  # Phlex views
      %r{^app/interactors/},
      %r{^app/operations/},
      %r{^app/commands/},
      %r{^app/use_cases/},
      %r{^app/jobs/},
      %r{^app/workers/},       # Sidekiq workers
      %r{^app/mailers/},
      %r{^app/graphql/}, # GraphQL types/mutations/resolvers
      %r{^app/serializers/},
      %r{^app/decorators/},
      %r{^app/blueprinters/},
      %r{^db/migrate/},
      %r{^db/schema\.rb$}, # Schema changes affect model metadata
      %r{^config/routes\.rb$},
      /^Gemfile\.lock$/ # Dependency changes trigger framework re-index
    ]

    changed_files = changed_files.select do |f|
      relevant_patterns.any? { |p| f.match?(p) }
    end

    if changed_files.empty?
      puts 'No relevant files changed. Skipping extraction.'
      exit 0
    end

    puts "Incremental extraction for #{changed_files.size} changed files..."
    changed_files.each { |f| puts "  - #{f}" }
    puts

    extractor = CodebaseIndex::Extractor.new(output_dir: output_dir)
    affected = extractor.extract_changed(changed_files)

    puts
    puts "Re-extracted #{affected.size} affected units."
  end

  desc 'Extract only Rails/gem framework sources (run when dependencies change)'
  task extract_framework: :environment do
    require 'codebase_index/extractors/rails_source_extractor'

    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index'))

    puts 'Extracting Rails and gem framework sources...'
    puts "Rails version: #{Rails.version}"
    puts

    extractor = CodebaseIndex::Extractors::RailsSourceExtractor.new
    units = extractor.extract_all

    # Write output
    framework_dir = Pathname.new(output_dir).join('rails_source')
    FileUtils.mkdir_p(framework_dir)

    units.each do |unit|
      file_name = "#{unit.identifier.gsub('/', '__').gsub('::', '__')}.json"
      File.write(
        framework_dir.join(file_name),
        JSON.pretty_generate(unit.to_h)
      )
    end

    puts "Extracted #{units.size} framework source units."
    puts "Output: #{framework_dir}"
  end

  desc 'Validate extracted index integrity'
  task validate: :environment do
    output_dir = Pathname.new(ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index')))

    unless output_dir.exist?
      puts "ERROR: Index directory does not exist: #{output_dir}"
      exit 1
    end

    manifest_path = output_dir.join('manifest.json')
    unless manifest_path.exist?
      puts 'ERROR: Manifest not found. Run extraction first.'
      exit 1
    end

    manifest = JSON.parse(File.read(manifest_path))

    puts 'Validating index...'
    puts "  Extracted at: #{manifest['extracted_at']}"
    puts "  Git SHA: #{manifest['git_sha']}"
    puts

    errors = []
    warnings = []

    # Check each type directory
    manifest['counts'].each do |type, expected_count|
      type_dir = output_dir.join(type)
      unless type_dir.exist?
        errors << "Missing directory: #{type}"
        next
      end

      actual_count = Dir[type_dir.join('*.json')].reject { |f| f.end_with?('_index.json') }.size

      warnings << "#{type}: expected #{expected_count}, found #{actual_count}" if actual_count != expected_count

      # Validate each unit file is valid JSON
      Dir[type_dir.join('*.json')].each do |file|
        next if file.end_with?('_index.json')

        begin
          data = JSON.parse(File.read(file))
          errors << "#{file}: missing identifier" unless data['identifier']
          errors << "#{file}: missing source_code" unless data['source_code']
        rescue JSON::ParserError => e
          errors << "#{file}: invalid JSON - #{e.message}"
        end
      end
    end

    # Check dependency graph
    graph_path = output_dir.join('dependency_graph.json')
    if graph_path.exist?
      begin
        JSON.parse(File.read(graph_path))
      rescue JSON::ParserError
        errors << 'dependency_graph.json: invalid JSON'
      end
    else
      errors << 'Missing dependency_graph.json'
    end

    # Report
    if errors.any?
      puts 'ERRORS:'
      errors.each { |e| puts "  ✗ #{e}" }
    end

    if warnings.any?
      puts 'WARNINGS:'
      warnings.each { |w| puts "  ⚠ #{w}" }
    end

    if errors.empty? && warnings.empty?
      puts '✓ Index is valid.'
    elsif errors.empty?
      puts "\n✓ Index is valid with #{warnings.size} warning(s)."
    else
      puts "\n✗ Index has #{errors.size} error(s)."
      exit 1
    end
  end

  desc 'Show index statistics'
  task stats: :environment do
    output_dir = Pathname.new(ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index')))

    unless output_dir.exist?
      puts 'Index directory does not exist. Run extraction first.'
      exit 1
    end

    manifest_path = output_dir.join('manifest.json')
    manifest = manifest_path.exist? ? JSON.parse(File.read(manifest_path)) : {}

    puts 'Codebase Index Statistics'
    puts '=' * 50
    puts "  Extracted at:  #{manifest['extracted_at'] || 'unknown'}"
    puts "  Rails version: #{manifest['rails_version'] || 'unknown'}"
    puts "  Ruby version:  #{manifest['ruby_version'] || 'unknown'}"
    puts "  Git SHA:       #{manifest['git_sha'] || 'unknown'}"
    puts "  Git branch:    #{manifest['git_branch'] || 'unknown'}"
    puts

    puts 'Units by Type'
    puts '-' * 50

    total_size = 0
    total_units = 0
    total_chunks = 0

    (manifest['counts'] || {}).each do |type, count|
      type_dir = output_dir.join(type)
      next unless type_dir.exist?

      type_size = Dir[type_dir.join('*.json')].sum { |f| File.size(f) }
      total_size += type_size
      total_units += count

      # Count chunks from index
      index_path = type_dir.join('_index.json')
      type_chunks = 0
      if index_path.exist?
        index = JSON.parse(File.read(index_path))
        type_chunks = index.sum { |u| u['chunk_count'] || 0 }
        total_chunks += type_chunks
      end

      puts "  #{type.ljust(15)}: #{count.to_s.rjust(4)} units, #{type_chunks.to_s.rjust(4)} chunks, #{(type_size / 1024.0).round(1).to_s.rjust(8)} KB"
    end

    puts '-' * 50
    puts "  #{'Total'.ljust(15)}: #{total_units.to_s.rjust(4)} units, #{total_chunks.to_s.rjust(4)} chunks, #{(total_size / 1024.0).round(1).to_s.rjust(8)} KB"
    puts

    # Dependency graph stats
    graph_path = output_dir.join('dependency_graph.json')
    if graph_path.exist?
      graph = JSON.parse(File.read(graph_path))
      stats = graph['stats'] || {}
      puts 'Dependency Graph'
      puts '-' * 50
      puts "  Nodes: #{stats['node_count'] || 'unknown'}"
      puts "  Edges: #{stats['edge_count'] || 'unknown'}"
    end
  end

  desc 'Clean extracted index'
  task clean: :environment do
    output_dir = Pathname.new(ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index')))

    if output_dir.exist?
      puts "Removing #{output_dir}..."
      FileUtils.rm_rf(output_dir)
      puts 'Done.'
    else
      puts 'Index directory does not exist.'
    end
  end

  desc 'Retrieve context for a query (for testing)'
  task :retrieve, [:query] => :environment do |_t, args|
    query = args[:query] || raise('Usage: rake codebase_index:retrieve[query]')

    require 'codebase_index'
    require 'codebase_index/retriever'
    require 'codebase_index/embedding/provider'
    require 'codebase_index/storage/vector_store'
    require 'codebase_index/storage/metadata_store'
    require 'codebase_index/storage/graph_store'
    require 'codebase_index/formatting/human_adapter'

    config = CodebaseIndex.configuration

    provider = CodebaseIndex::Embedding::Provider::Ollama.new
    vector_store = CodebaseIndex::Storage::VectorStore::InMemory.new
    metadata_store = CodebaseIndex::Storage::MetadataStore::SQLite.new
    graph_store = CodebaseIndex::Storage::GraphStore::Memory.new

    retriever = CodebaseIndex::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: provider
    )

    result = retriever.retrieve(query, budget: config.max_context_tokens)

    formatter = CodebaseIndex::Formatting::HumanAdapter.new
    puts formatter.format(result)
  end

  desc 'Embed all extracted units'
  task embed: :environment do
    require 'codebase_index'
    require 'codebase_index/embedding/indexer'
    require 'codebase_index/embedding/text_preparer'
    require 'codebase_index/embedding/provider'
    require 'codebase_index/storage/vector_store'

    config = CodebaseIndex.configuration
    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', config.output_dir)

    provider = CodebaseIndex::Embedding::Provider::Ollama.new
    text_preparer = CodebaseIndex::Embedding::TextPreparer.new
    vector_store = CodebaseIndex::Storage::VectorStore::InMemory.new

    indexer = CodebaseIndex::Embedding::Indexer.new(
      provider: provider,
      text_preparer: text_preparer,
      vector_store: vector_store,
      output_dir: output_dir
    )

    puts 'Embedding all extracted units...'
    stats = indexer.index_all

    puts
    puts 'Embedding complete!'
    puts "  Processed: #{stats[:processed]}"
    puts "  Skipped:   #{stats[:skipped]}"
    puts "  Errors:    #{stats[:errors]}"
  end

  desc 'Embed changed units only (incremental)'
  task embed_incremental: :environment do
    require 'codebase_index'
    require 'codebase_index/embedding/indexer'
    require 'codebase_index/embedding/text_preparer'
    require 'codebase_index/embedding/provider'
    require 'codebase_index/storage/vector_store'

    config = CodebaseIndex.configuration
    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', config.output_dir)

    provider = CodebaseIndex::Embedding::Provider::Ollama.new
    text_preparer = CodebaseIndex::Embedding::TextPreparer.new
    vector_store = CodebaseIndex::Storage::VectorStore::InMemory.new

    indexer = CodebaseIndex::Embedding::Indexer.new(
      provider: provider,
      text_preparer: text_preparer,
      vector_store: vector_store,
      output_dir: output_dir
    )

    puts 'Embedding changed units (incremental)...'
    stats = indexer.index_incremental

    puts
    puts 'Incremental embedding complete!'
    puts "  Processed: #{stats[:processed]}"
    puts "  Skipped:   #{stats[:skipped]}"
    puts "  Errors:    #{stats[:errors]}"
  end

  desc "Analyze the gem's own source code and generate self-analysis output"
  task :self_analyze do
    require 'digest'
    require 'json'
    require 'fileutils'
    require 'codebase_index/ruby_analyzer'
    require 'codebase_index/dependency_graph'
    require 'codebase_index/graph_analyzer'
    require 'codebase_index/ruby_analyzer/mermaid_renderer'

    gem_root = File.expand_path('../..', __dir__)
    json_dir = File.join(gem_root, 'tmp', 'codebase_index_self')
    docs_dir = File.join(gem_root, 'docs', 'self-analysis')
    manifest_path = File.join(json_dir, 'manifest.json')

    # 1. Check staleness via source_checksum
    lib_files = Dir.glob(File.join(gem_root, 'lib', '**', '*.rb')).sort
    source_content = lib_files.map { |f| File.read(f) }.join
    source_checksum = Digest::SHA256.hexdigest(source_content)

    if File.exist?(manifest_path)
      existing = JSON.parse(File.read(manifest_path))
      if existing['source_checksum'] == source_checksum
        puts 'Source unchanged — skipping self-analysis.'
        next
      end
    end

    puts 'Running self-analysis on gem source...'

    # 2. Run RubyAnalyzer
    units = CodebaseIndex::RubyAnalyzer.analyze(paths: [File.join(gem_root, 'lib', 'codebase_index')])
    puts "  Analyzed #{units.size} units"

    # 3. Build DependencyGraph + GraphAnalyzer
    graph = CodebaseIndex::DependencyGraph.new
    units.each { |unit| graph.register(unit) }
    analyzer = CodebaseIndex::GraphAnalyzer.new(graph)
    analysis = analyzer.analyze
    graph_data = graph.to_h

    # 4. Write JSON to tmp/codebase_index_self/
    FileUtils.mkdir_p(json_dir)

    units.each do |unit|
      file_name = "#{unit.identifier.gsub(/[^a-zA-Z0-9_]/, '_')}.json"
      File.write(
        File.join(json_dir, file_name),
        JSON.pretty_generate(unit.to_h)
      )
    end

    File.write(
      File.join(json_dir, 'dependency_graph.json'),
      JSON.pretty_generate(graph_data)
    )

    File.write(
      File.join(json_dir, 'analysis.json'),
      JSON.pretty_generate(analysis)
    )

    manifest = {
      'source_checksum' => source_checksum,
      'generated_at' => Time.now.iso8601,
      'unit_count' => units.size,
      'node_count' => graph_data[:stats][:node_count],
      'edge_count' => graph_data[:stats][:edge_count]
    }
    File.write(manifest_path, JSON.pretty_generate(manifest))

    # 5. Render Mermaid to docs/self-analysis/
    FileUtils.mkdir_p(docs_dir)
    renderer = CodebaseIndex::RubyAnalyzer::MermaidRenderer.new

    File.write(
      File.join(docs_dir, 'architecture.md'),
      renderer.render_architecture(units, graph_data, analysis)
    )

    File.write(
      File.join(docs_dir, 'call-graph.md'),
      "# Call Graph\n\n```mermaid\n#{renderer.render_call_graph(units)}\n```\n"
    )

    File.write(
      File.join(docs_dir, 'dependency-map.md'),
      "# Dependency Map\n\n```mermaid\n#{renderer.render_dependency_map(graph_data)}\n```\n"
    )

    File.write(
      File.join(docs_dir, 'dataflow.md'),
      "# Data Flow\n\n```mermaid\n#{renderer.render_dataflow(units)}\n```\n"
    )

    puts "  JSON output: #{json_dir}"
    puts "  Mermaid docs: #{docs_dir}"
    puts 'Self-analysis complete.'
  end

  desc 'Generate execution flow document for a Rails entry point'
  task :flow, [:entry_point] => :environment do |_t, args|
    require 'json'
    require 'codebase_index/flow_assembler'
    require 'codebase_index/dependency_graph'

    entry_point = args[:entry_point]
    unless entry_point
      puts 'Usage: rake codebase_index:flow[EntryPoint#method]'
      exit 1
    end

    output_dir = ENV.fetch('CODEBASE_INDEX_OUTPUT', Rails.root.join('tmp/codebase_index'))
    graph_path = File.join(output_dir, 'dependency_graph.json')

    unless File.exist?(graph_path)
      puts "ERROR: Dependency graph not found at #{graph_path}"
      puts 'Run codebase_index:extract first.'
      exit 1
    end

    graph_data = JSON.parse(File.read(graph_path))
    graph = CodebaseIndex::DependencyGraph.from_h(graph_data)

    max_depth = ENV.fetch('MAX_DEPTH', 5).to_i
    assembler = CodebaseIndex::FlowAssembler.new(graph: graph, extracted_dir: output_dir)
    flow = assembler.assemble(entry_point, max_depth: max_depth)

    format = ENV.fetch('FORMAT', 'markdown').downcase

    case format
    when 'json'
      puts JSON.pretty_generate(flow.to_h)
    else
      puts flow.to_markdown
    end
  end
end
