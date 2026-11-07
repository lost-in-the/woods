# frozen_string_literal: true

# Plans the booted (one Rails application per process) spec files as separate
# rspec processes, so a CI job runs them several at a time on its cores.
#
# A `:booted_app` spec boots `WoodsDummyApplication` in its process, and
# `Rails::Application` is a singleton, so every file keeps its own process
# except the files that already shared one before this runner existed
# ({SHARED_GROUPS}). The incremental-equivalence harness is one 7,000-line
# file, so it is split by its top-level groups into balanced buckets, and its
# randomized sequences run one seed per process.
require 'etc'
require 'rbconfig'

module ParallelBooted
  ROOT = File.expand_path('..', __dir__)
  HARNESS = 'spec/integration/incremental_equivalence_spec.rb'
  # Files that share one rspec process, exactly the sets ci.yml ran as one
  # process before this runner. Every other file runs alone.
  SHARED_GROUPS = [
    %w[spec/integration/booted_extraction_spec.rb spec/integration/lazy_routes_equivalence_spec.rb
       spec/integration/mailer_determinism_spec.rb spec/integration/validation_options_spec.rb
       spec/integration/concurrent_extraction_pool_spec.rb spec/integration/writer_fencing_booted_spec.rb],
    %w[spec/integration/source_input_drift_spec.rb spec/integration/source_output_spec.rb
       spec/integration/source_manifest_capacity_spec.rb],
    %w[spec/integration/watch_startup_spec.rb spec/integration/managed_watch_spec.rb]
  ].freeze
  # The harness's randomized example: one process per seed in WOODS_DIFF_SEEDS.
  RANDOMIZED_EXAMPLE = /^\s+it "stays equivalent to a full extraction over #\{DIFF_OPERATION_COUNT\} random operations/
  # A top-level declaration of the harness file: a group, an example, or a
  # loop that declares either, at the file's two-space indentation.
  TOP_LEVEL = /\A {2}(?:describe|context|it|%[iw]\[[^\]]*\]\.each|[A-Z_]+\.each)\b/
  # A group or example declaration at any depth. A loop is not one: RSpec
  # selects by the line an example or group is declared on, and a loop's
  # iterations all declare theirs on the one line inside it.
  DECLARATION = /\A\s+(?:describe|context|it)\b/
  DEFAULT_SEEDS = '1,2,3'
  # Fewer, larger GC cycles for an extraction-heavy process: the booted
  # harness spent a quarter of its wall time marking a large live heap at the
  # defaults (measured 4-10% faster on its slowest examples). Set
  # WOODS_BOOTED_GC_TUNING=0 to run the children at Ruby's defaults.
  GC_TUNING = {
    'RUBY_GC_MALLOC_LIMIT' => '134217728', 'RUBY_GC_MALLOC_LIMIT_MAX' => '1073741824',
    'RUBY_GC_OLDMALLOC_LIMIT' => '134217728', 'RUBY_GC_OLDMALLOC_LIMIT_MAX' => '1073741824',
    'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR' => '4.0', 'RUBY_GC_HEAP_GROWTH_FACTOR' => '2.0'
  }.freeze

  # One rspec process: its files (each optionally suffixed with `:LINE` filters),
  # the environment it adds, a label for the log, and a weight for scheduling.
  Job = Struct.new(:label, :arguments, :env, :weight, keyword_init: true)

  # One top-level declaration of the harness file: the line that selects it,
  # the lines it spans (its weight) and whether it is the randomized example.
  Declaration = Struct.new(:line, :weight, :randomized, keyword_init: true)

  # Plan every process for +files+: shared groups stay together, the harness
  # is split into +buckets+ line-filtered processes plus one per seed, and
  # every other file runs alone. Order is the schedule: heaviest first, so
  # the long processes start before the short ones fill in behind them.
  #
  # @param files [Array<String>] spec paths relative to the repository root
  # @param buckets [Integer] how many processes the harness's non-randomized
  #   groups are split across
  # @param seeds [String] the WOODS_DIFF_SEEDS the harness runs
  # @param harness_source [String] the harness file's text
  # @return [Array<Job>]
  def self.plan(files, buckets:, seeds: ENV.fetch('WOODS_DIFF_SEEDS', DEFAULT_SEEDS),
                harness_source: File.read(File.join(ROOT, HARNESS), encoding: 'UTF-8'))
    remaining = files.map { |file| file.delete_prefix("#{ROOT}/") }
    unknown = remaining.reject { |file| File.file?(File.join(ROOT, file)) }
    raise ArgumentError, "no such spec file: #{unknown.join(', ')}" unless unknown.empty?

    jobs = remaining.delete(HARNESS) ? harness_jobs(harness_source, buckets: buckets, seeds: seeds) : []
    jobs.concat(file_jobs(remaining))
    jobs.sort_by.with_index { |job, index| [-job.weight, index] }
  end

  # One job per complete shared group among +files+, then one per other file.
  #
  # @return [Array<Job>]
  def self.file_jobs(files)
    remaining = files.dup
    groups = SHARED_GROUPS.select { |group| (group & remaining).size == group.size }
    groups.each { |group| remaining -= group }
    jobs = groups.map { |group| Job.new(label: label_for(group.first), arguments: group, env: {}, weight: group.size) }
    jobs + remaining.map { |file| Job.new(label: label_for(file), arguments: [file], env: {}, weight: 1) }
  end

  def self.label_for(file)
    File.basename(file, '_spec.rb')
  end

  # The harness as several processes: its randomized example once per seed,
  # and every other top-level declaration in one of +buckets+ balanced
  # line-filtered processes.
  #
  # @return [Array<Job>]
  def self.harness_jobs(source, buckets:, seeds:)
    declarations = top_level_declarations(source)
    randomized, ordinary = declarations.partition(&:randomized)
    raise ArgumentError, 'the harness declares no randomized sequences example' if randomized.empty?

    jobs = seeds.split(',').map do |seed|
      Job.new(label: "harness-seed-#{seed}", arguments: ["#{HARNESS}:#{randomized.first.line}"],
              env: { 'WOODS_DIFF_SEEDS' => seed }, weight: 1_000)
    end
    split(ordinary, [buckets, ordinary.size].min).each_with_index do |bucket, index|
      lines = bucket.map(&:line).sort
      jobs << Job.new(label: "harness-#{index + 1}", arguments: ["#{HARNESS}:#{lines.join(':')}"], env: {},
                      weight: bucket.sum(&:weight))
    end
    jobs
  end

  # The harness file's top-level declarations with the lines each spans, the
  # weight that balances the buckets. A top-level loop is selected by the
  # first group or example declared inside it, which every iteration shares.
  # The declaration holding the randomized example is selected by that
  # example's own line, so a seed process runs it and nothing else.
  #
  # @param source [String]
  # @return [Array<Declaration>]
  # @raise [ArgumentError] when a top-level loop declares nothing
  def self.top_level_declarations(source)
    lines = source.lines
    starts = lines.each_index.select { |index| lines[index].match?(TOP_LEVEL) }
    starts.each_with_index.map { |start, position| declaration(lines, start, starts[position + 1] || lines.size) }
  end

  # The declaration for the top-level span +start...stop+ (0-based indexes).
  def self.declaration(lines, start, stop)
    randomized = (start...stop).find { |index| lines[index].match?(RANDOMIZED_EXAMPLE) }
    return Declaration.new(line: randomized + 1, weight: stop - start, randomized: true) if randomized

    selector = (start...stop).find { |index| lines[index].match?(DECLARATION) }
    raise ArgumentError, "no declaration inside the loop at #{HARNESS}:#{start + 1}" unless selector

    Declaration.new(line: selector + 1, weight: stop - start, randomized: false)
  end
  private_class_method :declaration

  # Greedy longest-first balancing of +items+ by weight into +count+ groups.
  # Deterministic for a given input order.
  #
  # @return [Array<Array>]
  def self.split(items, count)
    groups = Array.new(count) { [] }
    totals = Array.new(count, 0)
    items.sort_by.with_index { |item, index| [-item.weight, index] }.each do |item|
      target = totals.each_with_index.min_by { |total, index| [total, index] }.last
      groups[target] << item
      totals[target] += item.weight
    end
    groups.reject(&:empty?)
  end

  # The command for one job: the repository's rspec, no project options file,
  # a progress format, and the job's file arguments.
  #
  # @return [Array<String>]
  def self.command(job)
    [RbConfig.ruby, File.join(ROOT, 'bin', 'rspec'), '--options', File::NULL, '--require', 'spec_helper',
     '--format', 'progress', *job.arguments]
  end

  # The environment a job's process adds: its own, the GC tuning unless
  # opted out, and a private TMPDIR and TEST_ENV_NUMBER so no two processes
  # share a scratch path.
  #
  # @return [Hash{String => String}]
  def self.environment(job, index, tmpdir)
    env = ENV.fetch('WOODS_BOOTED_GC_TUNING', '1') == '0' ? {} : GC_TUNING.dup
    env.merge!('TEST_ENV_NUMBER' => index.to_s, 'TMPDIR' => tmpdir)
    env.merge!(job.env)
  end

  def self.default_jobs
    Integer(ENV.fetch('WOODS_PARALLEL_PROCESSES', Etc.nprocessors.to_s))
  end
end
