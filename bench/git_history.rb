# frozen_string_literal: true

# From each checkout (baseline then candidate):
#   bundle exec ruby /path/to/candidate/bench/git_history.rb /tmp/git-fixture result.json
# Creates a disposable synthetic repository only when the fixture directory does
# not exist. Reuse that SAME fixture for both runs. Output includes actual
# metadata so callers can verify equality, not just compare elapsed times.
require 'bundler/setup'
require 'active_support/all'
require 'woods'
require 'woods/extractor'
require 'json'
require 'logger'
require 'open3'
require 'pathname'
require 'tmpdir'

module GitHistoryBenchmark
  module_function

  def command(*args, **options)
    output, error, status = Open3.capture3(*args, **options)
    raise "Benchmark git command failed: #{error}" unless status.success?

    output
  end

  def fixture_stream
    stream = +''
    stamp = Time.now.to_i - (30 * 86_400)
    241.times do |commit|
      message = "change #{commit}"
      stream << "commit refs/heads/main\ncommitter Author#{commit % 2} <test@example.invalid> " \
                "#{stamp + (commit * 60)} +0000\ndata #{message.bytesize}\n#{message}\n"
      indices = commit.zero? ? (0...1200) : 100.times.map { |i| ((commit * 97) + i) % 1200 }
      indices.each do |index|
        body = "file #{index} change #{commit}\n"
        stream << "M 100644 inline app/services/file_#{format('%04d', index)}.rb\ndata #{body.bytesize}\n#{body}"
      end
      stream << "\n"
    end
    stream
  end

  def prepare(root)
    return if File.exist?(root)

    raise 'Keep the benchmark fixture under the system temporary directory' unless root.start_with?("#{Dir.tmpdir}/")

    Dir.mkdir(root)
    command('git', 'init', '-q', root)
    command('git', '-C', root, 'fast-import', '--quiet', stdin_data: fixture_stream)
    command('git', '-C', root, 'symbolic-ref', 'HEAD', 'refs/heads/main')
    command('git', '-C', root, 'reset', '--hard', '-q')
  end

  def measure(extractor, root, count)
    paths = count.times.map { |i| File.join(root, format('app/services/file_%04d.rb', i)) }
    elapsed = []
    data = nil
    6.times do |rep|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      data = extractor.send(:batch_git_data, paths)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      elapsed << duration if rep.positive? # Discard one warm-up.
    end
    { seconds: elapsed, median_seconds: elapsed.sort[2], metadata: data }
  end

  def run(root)
    prepare(root)
    Object.const_set(:Rails, Module.new)
    Rails.define_singleton_method(:root) { Pathname.new(root) }
    Rails.define_singleton_method(:logger) { Logger.new(File::NULL) }
    extractor = Woods::Extractor.new(output_dir: File.join(root, 'unused-output'))
    { fixture_head: command('git', '-C', root, 'rev-parse', 'HEAD').strip,
      ruby: RUBY_VERSION, git: command('git', '--version').strip,
      results: [1, 100, 1200].to_h { |count| [count, measure(extractor, root, count)] } }
  end
end

abort 'Usage: bundle exec ruby bench/git_history.rb /tmp/fixture /tmp/results.json' unless ARGV.size == 2

report = GitHistoryBenchmark.run(File.expand_path(ARGV[0]))
File.write(ARGV[1], JSON.pretty_generate(report))
puts JSON.generate(report[:results].transform_values { |row| row.except(:metadata) })
