# frozen_string_literal: true

# lib/tasks/woods.rake
#
# Rake tasks for codebase indexing.
# These can be run manually or integrated into CI pipelines.
#
# Usage:
#   bundle exec rake woods:extract          # Full extraction
#   bundle exec rake woods:incremental      # Changed files only
#   bundle exec rake woods:extract_framework # Rails/gem sources only
#   bundle exec rake woods:validate          # Validate index integrity
#   bundle exec rake woods:stats             # Show index statistics
#   bundle exec rake woods:clean             # Remove index
#   bundle exec rake woods:self_analyze      # Analyze gem's own source
#   bundle exec rake woods:flow[EntryPoint]  # Generate execution flow

namespace :woods do
  desc 'Full extraction of codebase for indexing'
  task extract: :environment do
    require 'woods/extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods'))

    puts 'Starting full codebase extraction...'
    puts "Output directory: #{output_dir}"
    puts

    extractor = Woods::Extractor.new(output_dir: output_dir)
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

  desc 'Scan the forest — full extraction (alias for extract)'
  task scan: :extract

  desc 'Incremental extraction based on git changes'
  task incremental: :environment do
    require 'woods/extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods'))

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

    # Filter to paths that imply extraction work. The rule set lives in
    # PathDispatcher alongside the dispatch itself — a second hand-maintained
    # pattern list here would drift, and a path this filter drops never
    # reaches the index however good the dispatch behind it is (#164).
    dispatcher = Woods::PathDispatcher.new
    changed_files = changed_files.reject(&:empty?).select { |f| dispatcher.relevant?(f) }

    if changed_files.empty?
      puts 'No relevant files changed. Skipping extraction.'
      exit 0
    end

    puts "Incremental extraction for #{changed_files.size} changed files..."
    changed_files.each { |f| puts "  - #{f}" }
    puts

    extractor = Woods::Extractor.new(output_dir: output_dir)
    affected = extractor.extract_changed(changed_files)

    puts
    puts "Re-extracted #{affected.size} affected units."
  end

  desc 'Tend the garden — incremental extraction (alias for incremental)'
  task tend: :incremental

  desc 'Extract only Rails/gem framework sources (run when dependencies change)'
  task extract_framework: :environment do
    require 'woods/extractors/rails_source_extractor'

    output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods'))

    puts 'Extracting Rails and gem framework sources...'
    puts "Rails version: #{Rails.version}"
    puts

    extractor = Woods::Extractors::RailsSourceExtractor.new
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
    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods')))

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

  desc 'Vet the data — validate index integrity (alias for validate)'
  task vet: :validate

  desc 'Show index statistics'
  task stats: :environment do
    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods')))

    unless output_dir.exist?
      puts 'Index directory does not exist. Run extraction first.'
      exit 1
    end

    manifest_path = output_dir.join('manifest.json')
    manifest = manifest_path.exist? ? JSON.parse(File.read(manifest_path)) : {}

    puts 'Woods Index Statistics'
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

  desc 'Take a look — show index statistics (alias for stats)'
  task look: :stats

  desc 'Clean extracted index'
  task clean: :environment do
    output_dir = Pathname.new(ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods')))

    if output_dir.exist?
      puts "Removing #{output_dir}..."
      FileUtils.rm_rf(output_dir)
      puts 'Done.'
    else
      puts 'Index directory does not exist.'
    end
  end

  desc 'Clear the brush — remove index (alias for clean)'
  task clear: :clean

  # Internal debugging tool — hidden from `rails -T`
  task :retrieve, [:query] => :environment do |_t, args|
    query = args[:query] || raise('Usage: rake woods:retrieve[query]')

    require 'woods'
    require 'woods/retriever'
    require 'woods/embedding/provider'
    require 'woods/storage/vector_store'
    require 'woods/storage/metadata_store'
    require 'woods/storage/graph_store'
    require 'woods/formatting/human_adapter'

    config = Woods.configuration

    provider = Woods::Embedding::Provider::Ollama.new
    vector_store = Woods::Storage::VectorStore::InMemory.new
    metadata_store = Woods::Storage::MetadataStore::SQLite.new
    graph_store = Woods::Storage::GraphStore::Memory.new

    retriever = Woods::Retriever.new(
      vector_store: vector_store,
      metadata_store: metadata_store,
      graph_store: graph_store,
      embedding_provider: provider
    )

    result = retriever.retrieve(query, budget: config.max_context_tokens)

    formatter = Woods::Formatting::HumanAdapter.new
    puts formatter.format(result)
  end

  desc 'Embed all extracted units'
  task embed: :environment do
    require 'woods'
    require 'woods/tasks'

    indexer = Woods::Tasks.build_embed_indexer
    puts 'Embedding all extracted units...'
    Woods::Tasks.print_embed_stats(indexer.index_all, mode: :full)
  end

  desc 'Nest the data — embed all units (alias for embed)'
  task nest: :embed

  desc 'Embed changed units only (incremental)'
  task embed_incremental: :environment do
    require 'woods'
    require 'woods/tasks'

    indexer = Woods::Tasks.build_embed_indexer
    puts 'Embedding changed units (incremental)...'
    Woods::Tasks.print_embed_stats(indexer.index_incremental, mode: :incremental)
  end

  desc 'Hone the blade — incremental embedding (alias for embed_incremental)'
  task hone: :embed_incremental

  # Internal debugging tool — hidden from `rails -T`
  task :self_analyze do
    require 'digest'
    require 'json'
    require 'fileutils'
    require 'woods/ruby_analyzer'
    require 'woods/dependency_graph'
    require 'woods/graph_analyzer'
    require 'woods/ruby_analyzer/mermaid_renderer'

    gem_root = File.expand_path('../..', __dir__)
    json_dir = File.join(gem_root, 'tmp', 'woods_self')
    docs_dir = File.join(gem_root, 'docs', 'self-analysis')
    manifest_path = File.join(json_dir, 'manifest.json')

    # 1. Check staleness via source_checksum
    lib_files = Dir.glob(File.join(gem_root, 'lib', '**', '*.rb'))
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
    units = Woods::RubyAnalyzer.analyze(paths: [File.join(gem_root, 'lib', 'woods')])
    puts "  Analyzed #{units.size} units"

    # 3. Build DependencyGraph + GraphAnalyzer
    graph = Woods::DependencyGraph.new
    units.each { |unit| graph.register(unit) }
    analyzer = Woods::GraphAnalyzer.new(graph)
    analysis = analyzer.analyze
    graph_data = graph.to_h

    # 4. Write JSON to tmp/woods_self/
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
    renderer = Woods::RubyAnalyzer::MermaidRenderer.new

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
    require 'woods/flow_assembler'
    require 'woods/dependency_graph'

    entry_point = args[:entry_point]
    unless entry_point
      puts 'Usage: rake woods:flow[EntryPoint#method]'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', Rails.root.join('tmp/woods'))
    graph_path = File.join(output_dir, 'dependency_graph.json')

    unless File.exist?(graph_path)
      puts "ERROR: Dependency graph not found at #{graph_path}"
      puts 'Run woods:extract first.'
      exit 1
    end

    graph_data = JSON.parse(File.read(graph_path))
    graph = Woods::DependencyGraph.from_h(graph_data)

    max_depth = ENV.fetch('MAX_DEPTH', 5).to_i
    assembler = Woods::FlowAssembler.new(graph: graph, extracted_dir: output_dir)
    flow = assembler.assemble(entry_point, max_depth: max_depth)

    format = ENV.fetch('FORMAT', 'markdown').downcase

    case format
    when 'json'
      puts JSON.pretty_generate(flow.to_h)
    else
      puts flow.to_markdown
    end
  end

  desc 'Start the embedded console MCP server (stdio transport)'
  task :console do
    # Capture stdout before Rails boot to keep MCP protocol clean.
    # Rails boot emits OpenTelemetry, gem warnings, etc. to stdout —
    # MCP client cannot parse these as JSON-RPC.
    # Global variable passes the fd to exe/woods-console via load.
    $woods_protocol_out = $stdout.dup # rubocop:disable Style/GlobalVars
    $stdout.reopen($stderr)

    Rake::Task[:environment].invoke

    load File.expand_path('../../exe/woods-console', __dir__)
  end

  desc 'Sync extraction data to Notion databases (Data Models + Columns)'
  task notion_sync: :environment do
    require 'woods/notion/exporter'

    config = Woods.configuration
    # A non-blank env var takes precedence over the configured value; a blank
    # NOTION_API_TOKEN is treated as absent. Shared resolution keeps the rake
    # task, the exporter, and the MCP tool consistent.
    config.notion_api_token = Woods.resolve_notion_token(config)

    unless config.notion_api_token
      puts 'ERROR: Notion API token not configured.'
      puts 'Set NOTION_API_TOKEN env var or configure notion_api_token in Woods.configure.'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)

    db_ids = config.notion_database_ids || {}
    if db_ids.empty?
      puts 'ERROR: No Notion database IDs configured.'
      puts 'Set notion_database_ids in Woods.configure:'
      puts '  config.notion_database_ids = { data_models: "db-uuid", columns: "db-uuid" }'
      exit 1
    end

    puts 'Syncing extraction data to Notion...'
    puts "  Output dir: #{output_dir}"
    puts "  Databases:  #{db_ids.keys.join(', ')}"
    puts

    exporter = Woods::Notion::Exporter.new(index_dir: output_dir)
    stats = exporter.sync_all

    puts 'Sync complete!'
    puts "  Data Models: #{stats[:data_models]} synced"
    puts "  Columns:     #{stats[:columns]} synced"

    if stats[:errors].any?
      puts "  Errors:      #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5
    end
  end

  desc 'Send findings from the field — sync to Notion (alias for notion_sync)'
  task send: :notion_sync

  desc 'Sync extraction data to Unblocked collection (Documents API)'
  task unblocked_sync: :environment do
    require 'woods/unblocked/exporter'

    config = Woods.configuration
    config.unblocked_api_token = ENV.fetch('UNBLOCKED_API_TOKEN', nil) || config.unblocked_api_token
    config.unblocked_collection_id = ENV.fetch('UNBLOCKED_COLLECTION_ID', nil) || config.unblocked_collection_id
    config.unblocked_repo_url = ENV.fetch('UNBLOCKED_REPO_URL', nil) || config.unblocked_repo_url

    unless config.unblocked_api_token
      puts 'ERROR: Unblocked API token not configured.'
      puts 'Set UNBLOCKED_API_TOKEN env var or configure unblocked_api_token in Woods.configure.'
      exit 1
    end

    unless config.unblocked_collection_id
      puts 'ERROR: Unblocked collection ID not configured.'
      puts 'Set UNBLOCKED_COLLECTION_ID env var or configure unblocked_collection_id in Woods.configure.'
      exit 1
    end

    unless config.unblocked_repo_url
      puts 'ERROR: Repository URL not configured.'
      puts 'Set UNBLOCKED_REPO_URL env var or configure unblocked_repo_url in Woods.configure.'
      puts 'Example: https://github.com/your-org/your-repo'
      exit 1
    end

    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)
    # Truthy set, so FLAG=false / FLAG=0 disables rather than silently enabling.
    env_flag = ->(name) { %w[1 true yes].include?(ENV.fetch(name, '').strip.downcase) }
    force_full = env_flag.call('UNBLOCKED_FORCE_FULL_SYNC')
    force_purge = env_flag.call('UNBLOCKED_FORCE_PURGE')

    puts 'Syncing extraction data to Unblocked...'
    puts "  Output dir:     #{output_dir}"
    puts "  Collection:     #{config.unblocked_collection_id}"
    puts "  Repo URL:       #{config.unblocked_repo_url}"
    puts '  Mode:           full re-sync (UNBLOCKED_FORCE_FULL_SYNC set)' if force_full
    puts

    exporter = Woods::Unblocked::Exporter.new(
      index_dir: output_dir,
      force_full: force_full,
      force_purge: force_purge
    )
    stats = exporter.sync_all

    puts
    puts 'Sync complete!'
    puts "  Documents synced:   #{stats[:synced]}"
    puts "  Documents skipped:  #{stats[:skipped]}"
    puts "  Documents deleted:  #{stats[:deleted]}"

    if stats[:errors].any?
      puts "  Errors:             #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5

      # Fail the task so CI notices — a printed-but-green run is invisible in
      # post-merge pipelines (a dead token would otherwise stay green forever).
      # Exception: budget exhaustion *with* partial progress is the expected
      # cold-start shape; it converges on the next run.
      budget_only = stats[:errors].all? { |e| e.include?('daily budget exhausted') }
      unless budget_only && stats[:synced].positive?
        puts
        puts 'Sync completed with errors — failing so CI surfaces it.'
        exit 1
      end
    end
  end

  desc 'Relay findings to Unblocked (alias for unblocked_sync)'
  task relay: :unblocked_sync

  desc 'Export extraction data to a self-contained Obsidian vault'
  task obsidian: :environment do
    require 'woods/obsidian/vault_exporter'

    config = Woods.configuration
    output_dir = ENV.fetch('WOODS_OUTPUT', config.output_dir)
    vault_path = ENV.fetch('WOODS_OBSIDIAN_VAULT', File.join(output_dir.to_s, 'obsidian_vault'))
    # Truthy set, so FLAG=false / FLAG=0 disables rather than silently enabling.
    env_flag = ->(name) { %w[1 true yes].include?(ENV.fetch(name, '').strip.downcase) }

    puts 'Exporting extraction data to an Obsidian vault...'
    puts "  Output dir: #{output_dir}"
    puts "  Vault:      #{vault_path}"
    puts

    begin
      exporter = Woods::Obsidian::VaultExporter.new(
        index_dir: output_dir,
        vault_path: vault_path,
        include_source: env_flag.call('WOODS_OBSIDIAN_INCLUDE_SOURCE'),
        include_framework: env_flag.call('WOODS_OBSIDIAN_INCLUDE_FRAMEWORK'),
        force_purge: env_flag.call('WOODS_OBSIDIAN_FORCE_PURGE')
      )
      stats = exporter.export_all
    rescue Woods::Obsidian::ExportError => e
      puts "ERROR: #{e.message}"
      exit 1
    end

    puts 'Export complete!'
    puts "  Notes:    #{stats[:exported]}"
    puts "  Indexes:  #{stats[:indexes]}"
    puts "  Swept:    #{stats[:swept]}"
    puts "  Skipped:  #{stats[:skipped]}"
    puts
    puts "Open it in Obsidian: 'Open folder as vault' -> #{vault_path}"

    if stats[:errors].any?
      puts "  Errors:   #{stats[:errors].size}"
      stats[:errors].first(5).each { |e| puts "    - #{e}" }
      puts "    ... and #{stats[:errors].size - 5} more" if stats[:errors].size > 5
      exit 1
    end
  end

  desc 'Render the codebase as an Obsidian vault (alias for obsidian)'
  task vault: :obsidian

  desc 'Generate a random bearer token for woods-mcp-http (WOODS_MCP_HTTP_TOKEN)'
  task :generate_token do
    require 'securerandom'
    token = SecureRandom.hex(32)
    puts token
    warn 'Set WOODS_MCP_HTTP_TOKEN to this value in the environment where woods-mcp-http runs,'
    warn 'and send it as `Authorization: Bearer <token>` from clients.'
  end
end
