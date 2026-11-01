# frozen_string_literal: true
require 'woods'
require 'woods/filename_utils'
require 'fileutils'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/published_lexical_retriever'
require 'objspace'
require 'tmpdir'
require 'digest'
require 'timeout'
$stdout.sync = true
count = Integer(ARGV.fetch(0))
mode = ARGV.fetch(1, 'all')
abort 'mode must be direct, reload or all' unless %w[direct reload all].include?(mode)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
measure = ->(&block) { start = clock.call; value = block.call; [(clock.call - start) * 1000, value] }
median = ->(values) { values.sort.fetch(values.size / 2) }
store = Woods::Storage::MetadataStore::InMemory.new
count.times do |i|
  name = format('Record%06d', i)
  source = "class #{name}; commonword " + ('ordinary ledger customer payment label ' * 12)
  source += ' rareword' if (i % 997).zero?
  source += ' foreignword' if i >= count * 9 / 10
  source += '; end'
  store.store(Woods::StorageIdentity.key(name, 'model'), {
    'identifier' => name, 'type' => 'model', 'file_path' => "app/models/#{name}.rb", 'source_code' => source,
    'metadata' => { 'package' => i < count / 10 ? 'packs/small' : 'packs/large' }
  })
end
keys = store.all_identifiers
unless mode == 'reload'
  GC.start
  heap_before = ObjectSpace.memsize_of_all
  build_ms, index = measure.call { Woods::Retrieval::LexicalIndex.new(metadata_store: store) }
  GC.start
  heap_delta = ObjectSpace.memsize_of_all - heap_before
  scopes = { narrow: keys.first(count / 10), broad: keys.first(count * 9 / 10), empty: [] }
  views = scopes.transform_values { |scope| index.restricted_to(scope) }
  views[:nested] = views[:broad].restricted_to(keys.first(count / 20))
  views[:root] = index
  queries = %w[rareword neverindexed commonword foreignword Record000000]
  results = {}
  digests = {}
  views.each do |name, view|
    queries.each do |query|
      view.execute(query: query)
      times = Array.new(11) { measure.call { view.execute(query: query) }.first }
      results["#{name}/#{query}"] = median.call(times)
      candidates = view.execute(query: query).candidates
      digests["#{name}/#{query}"] = Digest::SHA256.hexdigest(Marshal.dump(candidates))
    end
  end
  scopes.each do |name, scope|
    times = Array.new(11) { measure.call { index.restricted_to(scope).execute(query: 'rareword') }.first }
    results["prepare+query/#{name}"] = median.call(times)
  end
  detached = index.restricted_to(keys.first(1))
  views = index = nil
  GC.start
  heap_with_detached = ObjectSpace.memsize_of_all
  raise 'detached view lost its unit' unless detached.units.size == 1
  detached = nil
  GC.start
  detached_view_retained_bytes = heap_with_detached - ObjectSpace.memsize_of_all
  puts JSON.generate(phase: 'result', count: count, ruby: RUBY_DESCRIPTION,
                     build_ms: build_ms, retained_lexical_bytes: heap_delta,
                     detached_view_retained_bytes: detached_view_retained_bytes,
                     query_medians_ms: results, digests: digests)
  exit if mode == 'direct'
end
Dir.mktmpdir('wds40-reload-') do |directory|
  filename = Object.new.extend(Woods::FilenameUtils)
  %w[one two].each do |generation|
    target = File.join(directory, generation, 'models')
    FileUtils.mkdir_p(target)
    entries = []
    keys.each do |key|
      unit = store.find(key)
      unit['source_code'] = unit['source_code'].gsub('rareword', 'changedword') if generation == 'two'
      entries << { 'identifier' => unit.fetch('identifier') }
      File.write(File.join(target, filename.collision_safe_filename(unit.fetch('identifier'))), JSON.generate(unit))
    end
    File.write(File.join(target, '_index.json'), JSON.generate(entries))
    File.write(File.join(directory, generation, 'manifest.json'), JSON.generate('counts' => { 'models' => count }))
  end
  # The synthetic publisher's corpus is not part of the serving process.
  store = keys = nil
  GC.start
  marker = Woods::Generation.new(output_dir: directory)
  marker.bump!(payload: 'one')
  retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: directory)
  cold_ms, = measure.call { retriever.warmup! }
  packaged = Array.new(11) do
    measure.call { retriever.retrieve('rareword', packages: ['packs/small']) }.first
  end
  GC.start
  old_heap = ObjectSpace.memsize_of_all
  entered = Queue.new
  release = Queue.new
  # Block after the old scoped view exists, inside its real query pin.
  old_index = retriever.snapshot.last.pipeline.executor
  restrict = old_index.method(:restricted_to)
  old_index.define_singleton_method(:restricted_to) do |eligible|
    view = restrict.call(eligible)
    execute = view.method(:execute)
    view.define_singleton_method(:execute) do |**arguments|
      entered << true
      release.pop
      execute.call(**arguments)
    end
    view
  end
  in_flight = Thread.new { retriever.retrieve('rareword', packages: ['packs/small']) }
  Timeout.timeout(10) { entered.pop }
  marker.bump!(payload: 'two')
  puts JSON.generate(phase: 'reload_start')
  reload_start = clock.call
  build_reload_ms = simultaneous_heap = nil
  counts = Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: directory, hooks: {
    after_candidates: lambda do
      build_reload_ms = (clock.call - reload_start) * 1000
      GC.start
      simultaneous_heap = ObjectSpace.memsize_of_all
      puts JSON.generate(phase: 'overlap', old_generation: retriever.snapshot.first.first)
      sleep 0.05 # let an external RSS sampler observe both live generations
      release << true
    end
  })
  puts JSON.generate(phase: 'reload_end')
  previous = Timeout.timeout(10) { in_flight.value }
  raise 'old pin changed' unless previous.sources.all? { |source| source[:generation] == 1 } && !previous.sources.empty?
  fresh = retriever.retrieve('changedword', packages: ['packs/small'])
  raise 'new snapshot missing' unless fresh.sources.all? { |source| source[:generation] == 2 } && !fresh.sources.empty?
  raise 'old tokens leaked' unless retriever.retrieve('rareword', packages: ['packs/small']).sources.empty?
  puts JSON.generate(phase: 'result', count: count, ruby: RUBY_DESCRIPTION,
                     packaged_cold_ms: cold_ms, packaged_scoped_ms: median.call(packaged),
                     reload_candidate_ms: build_reload_ms, old_heap_bytes: old_heap,
                     simultaneous_heap_bytes: simultaneous_heap, counts: counts)
end
