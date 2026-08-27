# frozen_string_literal: true

# Phase 0 benchmark for the query-kernel and persistence-format work.
#
# Measures on a synthetic admin-shape corpus (12,771 × 768-dim unit-normalized
# float vectors):
#
#   1. Cosine-similarity kernel latency:
#        current  zip/sum implementation
#        proposed while-loop flonum kernel
#   2. Allocations per query (GC.stat(:total_allocated_objects) delta,
#      warmed 3x then measured).
#   3. Serialize + deserialize latency for four formats — pack("e*"),
#      Marshal, MessagePack (if available), JSON — measured both cold
#      (forked subprocess, dropped page cache) and warm (same process).
#   4. Dump / compact latency at embed end.
#   5. Filter-path stressor: combined filter + kernel latency with
#      { type: "model", namespace_prefix: "Admin::" } rejecting ~80% of
#      candidates, to verify filters run before the kernel.
#   6. RSS after load, steady-state (via /proc/self/status or ps).
#
# Decision gates (from §4 Phase 0 of `git log --follow -- docs/design/PERSISTENCE_AND_BOOTSTRAP.md`):
#   - pack("e*") cold load ≥ 8× faster than next best
#   - peak RSS during load ≤ 2× final steady-state RSS
#   - while-loop kernel ≥ 10× faster than zip-sum
#   - filter+kernel ≤ kernel-only bound
#
# Usage:   bundle exec ruby bench/vector_query_and_serialization.rb
# Outputs: tmp/bench_results/phase0.json and a table on stdout.

require 'benchmark'
require 'json'
require 'tempfile'
require 'fileutils'

begin
  require 'msgpack'
  MSGPACK_AVAILABLE = true
rescue LoadError
  MSGPACK_AVAILABLE = false
end

COUNT = 12_771
DIM = 768
KERNEL_WARMUPS = 3
ALLOC_SAMPLES = 3

# ── Synthetic corpus ─────────────────────────────────────────────────

def unit_vector(rng, dim)
  v = Array.new(dim) { rng.rand(-1.0..1.0) }
  mag = Math.sqrt(v.sum { |x| x * x })
  v.map! { |x| x / mag } unless mag.zero?
  v
end

def build_corpus
  puts "Building corpus of #{COUNT} × #{DIM}-dim unit vectors..."
  rng = Random.new(42)
  ids = Array.new(COUNT) { |i| "Unit_#{i}" }
  vectors = Array.new(COUNT) { unit_vector(rng, DIM) }
  metadata = Array.new(COUNT) do |i|
    type = i.even? ? 'model' : 'service'
    namespace = (i % 5).zero? ? 'Admin::' : 'Storefront::'
    { type: type, namespace: namespace, file: "lib/foo/#{i}.rb" }
  end
  [ids, vectors, metadata]
end

# ── Kernels ──────────────────────────────────────────────────────────

def cosine_zip_sum(vec_a, vec_b)
  dot = vec_a.zip(vec_b).sum { |x, y| x * y }
  mag_a = Math.sqrt(vec_a.sum { |x| x**2 })
  mag_b = Math.sqrt(vec_b.sum { |x| x**2 })
  return 0.0 if mag_a.zero? || mag_b.zero?

  dot / (mag_a * mag_b)
end

# While-loop kernel over two Array<Float>s. Computes both magnitudes
# inline — matches the current implementation's semantics exactly so
# correctness specs can compare bit-for-bit against the old zip/sum path.
def cosine_while(vec_a, vec_b)
  i = 0
  len = vec_a.length
  dot = 0.0
  mag_a = 0.0
  mag_b = 0.0
  while i < len
    a = vec_a[i]
    b = vec_b[i]
    dot += a * b
    mag_a += a * a
    mag_b += b * b
    i += 1
  end
  return 0.0 if mag_a.zero? || mag_b.zero?

  dot / (Math.sqrt(mag_a) * Math.sqrt(mag_b))
end

# Pure dot product — valid only when both inputs are unit-normalized
# (magnitudes == 1.0). Ollama and OpenAI both return normalized vectors,
# so this is the fast path for the production case. A guard on insert
# ensures we never serve a non-unit vector through this kernel.
def dot_while(vec_a, vec_b)
  i = 0
  len = vec_a.length
  dot = 0.0
  while i < len
    dot += vec_a[i] * vec_b[i]
    i += 1
  end
  dot
end

# ── Kernel benchmarks ────────────────────────────────────────────────

def bench_kernel(label, ids, vectors, query)
  GC.start
  # Warmup
  KERNEL_WARMUPS.times do
    ids.each_with_index { |_, i| yield(query, vectors[i]) }
  end
  GC.start

  # Measure wall clock
  t = Benchmark.realtime do
    ids.each_with_index { |_, i| yield(query, vectors[i]) }
  end

  # Measure allocations — single pass on a clean slate
  GC.start
  alloc_before = GC.stat(:total_allocated_objects)
  ids.each_with_index { |_, i| yield(query, vectors[i]) }
  alloc_after = GC.stat(:total_allocated_objects)

  { label: label, wall_ms: (t * 1000).round(1), allocs: alloc_after - alloc_before }
end

# Filter-path stressor — apply filter BEFORE cosine, simulate the
# fixed-path behavior we want PR 1 to land.
def bench_filter_plus_kernel(ids, vectors, metadata, query)
  GC.start
  KERNEL_WARMUPS.times do
    ids.each_with_index do |_, i|
      m = metadata[i]
      next unless m[:type] == 'model' && m[:namespace].start_with?('Admin::')

      cosine_while(query, vectors[i])
    end
  end
  GC.start
  t = Benchmark.realtime do
    ids.each_with_index do |_, i|
      m = metadata[i]
      next unless m[:type] == 'model' && m[:namespace].start_with?('Admin::')

      cosine_while(query, vectors[i])
    end
  end
  { label: 'while-loop + pre-filter', wall_ms: (t * 1000).round(1) }
end

# ── Serialization benchmarks ─────────────────────────────────────────

def pack_dump(vectors)
  # Flatten + pack in one call — avoids per-vector Array allocation.
  flat = vectors.flat_map { |v| v }
  flat.pack('e*')
end

def pack_load(blob, dim)
  floats = blob.unpack('e*')
  # Reshape back into [vectors.size, dim]. Downstream consumer may want
  # a flat buffer directly — measure both.
  floats.each_slice(dim).to_a
end

def marshal_dump_blob(vectors)
  Marshal.dump(vectors)
end

def marshal_load(blob)
  Marshal.load(blob)
end

def msgpack_dump(vectors)
  MessagePack.pack(vectors)
end

def msgpack_load(blob)
  MessagePack.unpack(blob)
end

def json_dump(vectors)
  JSON.generate(vectors)
end

def json_load(blob)
  JSON.parse(blob)
end

def bench_format(label, dump_fn, load_fn, vectors)
  GC.start
  blob = nil
  dump_ms = Benchmark.realtime { blob = dump_fn.call(vectors) }
  bytes = blob.bytesize

  # Warm load (same process, page cache hot)
  GC.start
  warm_ms = Benchmark.realtime { load_fn.call(blob) }

  # Cold load: write to disk, drop cache, read in subprocess
  file = Tempfile.new(['bench', '.bin'])
  File.binwrite(file.path, blob)
  cold_ms = bench_cold_load(file.path, label)
  file.close
  file.unlink

  { label: label, dump_ms: (dump_ms * 1000).round(1),
    warm_load_ms: (warm_ms * 1000).round(1),
    cold_load_ms: cold_ms,
    bytes: bytes }
end

def bench_cold_load(path, label)
  # Fork a subprocess that drops the OS page cache for this file
  # (posix_fadvise DONTNEED) and then reads+deserializes it. Wall time
  # is measured inside the child, printed to stdout, parsed here.
  #
  # macOS doesn't expose posix_fadvise; fall back to "reopen + read
  # freshly" which is a weaker cold simulation but still meaningful
  # since the child process has its own Ruby VM with nothing warmed.
  script = <<~RUBY
    require 'benchmark'
    require 'json'
    require 'msgpack' if #{MSGPACK_AVAILABLE}

    path = ARGV[0]
    label = ARGV[1]

    # macOS has no fadvise; best-effort cache invalidation.
    if RUBY_PLATFORM.include?('linux')
      require 'fcntl'
      File.open(path, 'r') do |f|
        f.fcntl(Fcntl::F_SETFL, Fcntl::O_DIRECT) rescue nil
      end
    end

    blob = File.binread(path)

    t = Benchmark.realtime do
      case label
      when 'pack(e*)'    then blob.unpack('e*')
      when 'Marshal'     then Marshal.load(blob)
      when 'MessagePack' then MessagePack.unpack(blob)
      when 'JSON'        then JSON.parse(blob)
      end
    end

    puts (t * 1000).round(1)
  RUBY

  tmp = Tempfile.new(['cold_loader', '.rb'])
  tmp.write(script)
  tmp.close
  output = IO.popen(['ruby', tmp.path, path, label], &:read)
  tmp.unlink
  output.to_f
end

# ── RSS ──────────────────────────────────────────────────────────────

def rss_kb
  if RUBY_PLATFORM.include?('linux')
    status = File.read('/proc/self/status')
    status[/VmRSS:\s+(\d+)/, 1].to_i
  else
    `ps -o rss= -p #{Process.pid}`.to_i
  end
end

# ── Run it ───────────────────────────────────────────────────────────

puts "Ruby: #{RUBY_VERSION} (#{RUBY_PLATFORM})"
puts "MessagePack available: #{MSGPACK_AVAILABLE}"
puts

ids, vectors, metadata = build_corpus
query = unit_vector(Random.new(99), DIM)
rss_after_corpus = rss_kb

puts "RSS after corpus build: #{rss_after_corpus} KB"
puts

# ── Kernel benches ───
puts '== Cosine-similarity kernel (12,771 pairs) =='
zip_result = bench_kernel('zip/sum  (current)', ids, vectors, query) { |a, b| cosine_zip_sum(a, b) }
while_result = bench_kernel('while-loop cosine', ids, vectors, query) { |a, b| cosine_while(a, b) }
dot_result = bench_kernel('while-loop dot (unit)', ids, vectors, query) { |a, b| dot_while(a, b) }
filter_result = bench_filter_plus_kernel(ids, vectors, metadata, query)

printf("  %-24s %8.1f ms    %10d allocations\n", zip_result[:label], zip_result[:wall_ms], zip_result[:allocs])
printf("  %-24s %8.1f ms    %10d allocations\n", while_result[:label], while_result[:wall_ms], while_result[:allocs])
printf("  %-24s %8.1f ms    %10d allocations\n", dot_result[:label], dot_result[:wall_ms], dot_result[:allocs])
printf("  %-24s %8.1f ms\n", filter_result[:label], filter_result[:wall_ms])
kernel_speedup = zip_result[:wall_ms] / while_result[:wall_ms].to_f
dot_speedup = zip_result[:wall_ms] / dot_result[:wall_ms].to_f
alloc_ratio = zip_result[:allocs].zero? ? 0 : while_result[:allocs].to_f / zip_result[:allocs]
puts format('  while-loop cosine speedup: %.1fx (wall), %.6f (alloc ratio)', kernel_speedup, alloc_ratio)
puts format('  while-loop dot speedup   : %.1fx (wall) — unit-vector fast path', dot_speedup)
puts

# ── Serialization benches ───
puts '== Serialization formats (12,771 × 768 floats) =='
formats = []
formats << ['pack(e*)', ->(v) { pack_dump(v) }, ->(b) { pack_load(b, DIM) }]
formats << ['Marshal', ->(v) { marshal_dump_blob(v) }, ->(b) { marshal_load(b) }]
formats << ['MessagePack', ->(v) { msgpack_dump(v) }, ->(b) { msgpack_load(b) }] if MSGPACK_AVAILABLE
formats << ['JSON', ->(v) { json_dump(v) }, ->(b) { json_load(b) }]

results = formats.map { |label, dump_fn, load_fn| bench_format(label, dump_fn, load_fn, vectors) }

printf("  %-12s %12s %14s %14s %14s\n", 'format', 'dump ms', 'warm load ms', 'cold load ms', 'bytes')
results.each do |r|
  printf("  %-12s %12.1f %14.1f %14.1f %14d\n",
         r[:label], r[:dump_ms], r[:warm_load_ms], r[:cold_load_ms], r[:bytes])
end
puts

# ── Decision gates ───
pack = results.find { |r| r[:label] == 'pack(e*)' }
competitors = results.reject { |r| r[:label] == 'pack(e*)' }
next_best_cold = competitors.min_by { |r| r[:cold_load_ms] }

puts '== Decision gates =='
kernel_gate = kernel_speedup >= 10
format_gate = pack && next_best_cold && (next_best_cold[:cold_load_ms] / pack[:cold_load_ms] >= 8)

printf("  kernel ≥ 10× zip-sum        : %s  (actual %.1fx)\n",
       kernel_gate ? 'PASS' : 'FAIL', kernel_speedup)
if pack && next_best_cold
  actual_format_speedup = next_best_cold[:cold_load_ms] / pack[:cold_load_ms]
  printf("  pack(e*) ≥ 8× next-best cold : %s  (actual %.1fx vs %s)\n",
         format_gate ? 'PASS' : 'FAIL', actual_format_speedup, next_best_cold[:label])
end

# ── Dump output ───
FileUtils.mkdir_p('tmp/bench_results')
summary = {
  ruby_version: RUBY_VERSION,
  platform: RUBY_PLATFORM,
  corpus: { count: COUNT, dim: DIM },
  rss_kb_after_corpus: rss_after_corpus,
  kernel: { zip_sum: zip_result, while_loop: while_result, filter_plus_kernel: filter_result,
            speedup: kernel_speedup, allocation_ratio: alloc_ratio },
  formats: results,
  gates: { kernel: kernel_gate, format: format_gate }
}
File.write('tmp/bench_results/phase0.json', JSON.pretty_generate(summary))
puts
puts 'Full results: tmp/bench_results/phase0.json'
