# frozen_string_literal: true

# Lexical snapshot cost across generations in one process: the first query
# of a fresh process, a refresh after a one-file change, a no-op refresh, and
# RSS at peak, at steady state and after ten refreshes.
#
#   ruby -I lib bench/lexical_token_reuse.rb INDEX_DIR [QUERY]
#
# INDEX_DIR is a published Woods index (for example the self-map from
# `bin/rake "woods:self_map[/tmp/map]"`). It is copied, with hard links,
# into a temporary directory; every new generation there replaces whole
# files, so the source index is never modified.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require 'woods'
require 'woods/mcp/published_lexical_retriever'
require 'fileutils'
require 'json'
require 'tmpdir'
$stdout.sync = true

source = File.expand_path(ARGV.fetch(0))
query = ARGV.fetch(1, 'lexical index token cache')
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
rss = lambda do
  status = File.read('/proc/self/status')
  { rss_mb: status[/^VmRSS:\s+(\d+)/, 1].to_i / 1024.0, peak_mb: status[/^VmHWM:\s+(\d+)/, 1].to_i / 1024.0 }
end
cpu = -> { Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) }
# Wall and process CPU time: CPU time is the steadier figure on a shared host.
timed = lambda do |&block|
  start = clock.call
  start_cpu = cpu.call
  value = block.call
  [{ wall_ms: ((clock.call - start) * 1000).round, cpu_ms: ((cpu.call - start_cpu) * 1000).round }, value]
end

Dir.mktmpdir('woods-lexical-reuse-') do |directory|
  FileUtils.cp_r(Dir.glob(File.join(source, '*')), directory, preserve: true)
  marker = JSON.parse(File.read(File.join(directory, 'generation.json')))
  base = File.join(directory, marker.fetch('payload'))
  unit_files = Dir.glob(File.join(base, '*', '*.json')).reject { |path| path.end_with?('_index.json') }.sort
  target = unit_files.find { |path| JSON.parse(File.read(path))['source_code'].to_s.size > 200 }
  sequence = 0
  publish = lambda do |change|
    sequence += 1
    relative = "payloads/bench-#{sequence}"
    payload = File.join(directory, relative)
    system('cp', '-al', base, payload, exception: true)
    if change
      copy = File.join(payload, target.delete_prefix("#{base}/"))
      data = JSON.parse(File.read(copy))
      data['source_code'] = "#{data['source_code']}\n# benchword#{sequence}"
      File.unlink(copy)
      File.write(copy, JSON.generate(data))
    end
    Woods::Generation.new(output_dir: directory).bump!(payload: relative)
  end

  retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: directory)
  cache = Woods::Retrieval::LexicalTokenCache.shared if defined?(Woods::Retrieval::LexicalTokenCache)
  first_ms, result = timed.call { retriever.retrieve(query) }
  report = {
    units: retriever.metadata_store.count, ruby: RUBY_DESCRIPTION, token_cache: !cache.nil?,
    fresh_process: { boot_to_first_answer_ms: ((clock.call - started) * 1000).round, first_query: first_ms,
                     sources: result.sources.size, cache: cache&.stats },
    after_first_query: rss.call
  }
  GC.start
  report[:steady_state] = rss.call

  publish.call(true)
  ms, = timed.call { retriever.retrieve(query) }
  report[:one_file_change_refresh] = { query: ms, cache: cache&.stats }
  publish.call(false)
  ms, = timed.call { retriever.retrieve(query) }
  report[:no_op_refresh] = { query: ms, cache: cache&.stats }
  ms, = timed.call { retriever.retrieve(query) }
  report[:same_generation_query] = ms

  times = Array.new(10) do
    publish.call(true)
    timed.call { retriever.retrieve(query) }.first
  end
  GC.start
  report[:after_ten_refreshes] = rss.call.merge(refresh_queries: times, cache: cache&.stats)
  puts JSON.pretty_generate(report)
end
