# frozen_string_literal: true

# Run this same script against two checkouts via WOODS_SOURCE. BENCH_ROOT must
# name an existing directory on the filesystem being evaluated, not the index.
require 'benchmark'
require 'tmpdir'
require 'fileutils'
require 'json'
require File.join(ENV.fetch('WOODS_SOURCE', File.expand_path('..', __dir__)), 'lib/woods/payload_store')

count = Integer(ENV.fetch('BENCH_FILES', '8335'))
repeats = Integer(ENV.fetch('BENCH_REPEATS', '7'))
raise ArgumentError, 'counts must be positive' unless count.positive? && repeats.positive?

root = Dir.mktmpdir('woods-payload-benchmark-', ENV.fetch('BENCH_ROOT'))
begin
  store = Woods::PayloadStore.new(root)
  source = store.create(1)
  35.times { |i| FileUtils.mkdir_p(source.join("type#{i}")) }
  count.times { |i| File.binwrite(source.join("type#{i % 35}/Unit#{i}.json"), 'x' * 2048) }
  samples = Array.new(repeats) do
    target = store.create(2)
    GC.start
    allocations = GC.stat(:total_allocated_objects)
    seconds = Benchmark.realtime { store.clone(source, target) }
    allocations = GC.stat(:total_allocated_objects) - allocations
    files = Dir.glob(target.join('**/*.json').to_s)
    raise 'missing files' unless files.size == count
    files.each { |path| raise 'changed bytes' unless File.binread(path) == 'x' * 2048 }
    { seconds: seconds, allocations: allocations }
  end
  puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, files: count, bytes_per_file: 2048,
                            samples: samples, median_seconds: samples.map { |s| s[:seconds] }.sort[repeats / 2],
                            median_allocations: samples.map { |s| s[:allocations] }.sort[repeats / 2])
ensure
  FileUtils.rm_rf(root)
end
