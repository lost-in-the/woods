# frozen_string_literal: true

# Benchmark: Woods::AtomicFile durability modes
#
# What this measures:
#   Every payload file an extraction writes goes through
#   `Woods::AtomicFile.write`. Until the deferred-durability change that was
#   a tempfile fsync plus a directory fsync per file: two forced flushes,
#   8323 times on a large host application, which was the whole of the write
#   phase.
#
#   The replacement writes the payload without any fsync and makes it durable
#   with one `Woods::AtomicFile.sync_directory_tree` call before
#   `generation.json` is written. The guarantee is unchanged where it counts:
#   when the pointer is durable, every file in the payload it names is
#   durable. Nothing reads a payload file before the pointer names it.
#
#   Four modes, same file count, same directory:
#
#     1. durable (today's per-file fsync), the `durable_payload_writes = true`
#        setting
#     2. deferred: no per-file fsync, then one `sync_directory_tree`  <- default
#     3. no fsync at all, the floor, not a mode Woods ships
#     4. plain `File.binwrite`, not atomic, for scale only
#
# How to run:
#   bundle exec ruby bench/atomic_write_bench.rb
#   FILES=2000 bundle exec ruby bench/atomic_write_bench.rb
#   WOODS_BENCH_DIR=/mnt/somewhere bundle exec ruby bench/atomic_write_bench.rb
#
#   The default directory is `tmp/atomic_write_bench` inside this checkout,
#   which is gitignored.
#
# **Do not run this under /tmp.** On most Linux distributions /tmp is tmpfs,
# which has no backing device: fsync is a no-op there and every mode reports
# the same number. The bench prints the filesystem type it measured and warns
# when that type cannot show the cost.
#
# What "good" looks like:
#   Mode 2 lands within a small multiple of mode 3, and one to two orders of
#   magnitude below mode 1. Measured on btrfs, 8000 files of about 2 KB: 71.3s
#   durable against 1.0s deferred.

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'benchmark'
require 'fileutils'
require 'shellwords'
require 'woods/atomic_file'

FILES = Integer(ENV.fetch('FILES', 8000))
DEFAULT_DIR = File.expand_path('../tmp/atomic_write_bench', __dir__)
BENCH_DIR = File.expand_path(ENV.fetch('WOODS_BENCH_DIR', DEFAULT_DIR))

# About 2 KB, the shape of a small unit file.
CONTENT = "{\"identifier\":\"App::Thing\",\"type\":\"model\",#{'"key":"value",' * 130}\"chunks\":[]}"

# Filesystems with no backing device. fsync costs nothing on them, so every
# mode below reports the same number and the bench says nothing at all.
VOLATILE_FILESYSTEMS = %w[tmpfs ramfs].freeze

def filesystem_type(path)
  type = `stat -f -c %T #{path.shellescape} 2>/dev/null`.strip
  type.empty? ? 'unknown' : type
rescue StandardError
  'unknown'
end

# @return [Float] seconds the block took, on the monotonic clock
def measure
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

# A fresh directory per mode, so no mode benefits from another's warm cache.
def in_clean_directory(name)
  directory = File.join(BENCH_DIR, name)
  FileUtils.rm_rf(directory)
  FileUtils.mkdir_p(File.join(directory, 'models'))
  yield directory
ensure
  FileUtils.rm_rf(directory)
end

def unit_path(directory, index)
  File.join(directory, 'models', "Unit#{index}.json")
end

FileUtils.mkdir_p(BENCH_DIR)
type = filesystem_type(BENCH_DIR)

puts "files:      #{FILES}  (#{CONTENT.bytesize} bytes each)"
puts "directory:  #{BENCH_DIR}"
puts "filesystem: #{type}"
if VOLATILE_FILESYSTEMS.include?(type)
  puts
  puts "WARNING: #{type} has no backing device, so fsync is free and every mode"
  puts '         below will report the same number. Point WOODS_BENCH_DIR at a'
  puts '         directory on a real filesystem.'
end
puts

results = {}

results['durable (per-file fsync)'] = in_clean_directory('durable') do |directory|
  measure do
    FILES.times { |i| Woods::AtomicFile.write(unit_path(directory, i), CONTENT) }
  end
end

strategy = nil
results['deferred (one flush)'] = in_clean_directory('deferred') do |directory|
  measure do
    FILES.times { |i| Woods::AtomicFile.write(unit_path(directory, i), CONTENT, durable: false) }
    strategy = Woods::AtomicFile.sync_directory_tree(directory)
  end
end

results['no flush at all'] = in_clean_directory('unflushed') do |directory|
  measure do
    FILES.times { |i| Woods::AtomicFile.write(unit_path(directory, i), CONTENT, durable: false) }
  end
end

results['plain binwrite (not atomic)'] = in_clean_directory('binwrite') do |directory|
  measure do
    FILES.times { |i| File.binwrite(unit_path(directory, i), CONTENT) }
  end
end

baseline = results.fetch('durable (per-file fsync)')
puts format('%-30<mode>s %10<total>s %12<each>s %9<speedup>s', mode: 'mode', total: 'total',
                                                               each: 'per file', speedup: 'vs today')
results.each do |label, seconds|
  puts format(
    '%-30<mode>s %9<total>.2fs %10<each>.2fms %8<speedup>.1fx',
    mode: label, total: seconds, each: seconds * 1000.0 / FILES, speedup: baseline / seconds
  )
end

puts
puts "sync_directory_tree strategy: #{strategy.inspect}"
