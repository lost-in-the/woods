# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../../script/parallel_booted'

# script/parallel-booted runs the booted spec files as separate rspec
# processes, several at a time. Each booted file boots its own Rails
# application, so the contracts here hold the plan to one process per file
# (or per set of files that always shared one), split the incremental
# equivalence harness without losing or repeating a top-level group, and keep
# ci.yml running every booted file through the runner.
RSpec.describe ParallelBooted do
  let(:harness_source) { File.read(File.join(described_class::ROOT, described_class::HARNESS), encoding: 'UTF-8') }
  let(:ci) { YAML.safe_load_file(File.expand_path('../../.github/workflows/ci.yml', __dir__), aliases: true) }
  let(:rails_steps) { ci.fetch('jobs').fetch('rails-matrix').fetch('steps') }

  def step(name)
    rails_steps.find { |entry| entry['name'] == name } or raise "no step #{name.inspect}"
  end

  describe '.top_level_declarations' do
    it 'finds every top-level group and example of the harness once, with the randomized example by its own line' do
      declarations = described_class.top_level_declarations(harness_source)
      lines = harness_source.lines
      expected = lines.each_index.select { |index| lines[index].match?(described_class::TOP_LEVEL) }

      expect(declarations.size).to eq(expected.size)
      expect(declarations.map(&:line)).to all(be_a(Integer))
      expect(declarations.map(&:weight)).to all(be_positive)
      randomized = declarations.select(&:randomized)
      expect(randomized.size).to eq(1)
      expect(lines[randomized.first.line - 1]).to match(described_class::RANDOMIZED_EXAMPLE)
      ordinary = declarations.reject(&:randomized).map(&:line)
      expect(ordinary).to eq(ordinary.uniq)
      expect(ordinary.map { |line| lines[line - 1] }).to all(match(described_class::DECLARATION))
    end

    it 'selects a top-level loop by the example declared inside it, and skips helpers and nested groups' do
      source = <<~RUBY
        RSpec.describe 'x' do
          describe 'a' do
            it 'inner' do
            end
          end
          def helper
          end
          %i[flat generation].each do |layout|
            it "keeps \#{layout}" do
            end
          end
          it 'top' do
          end
        end
      RUBY
      expect(described_class.top_level_declarations(source).map(&:line)).to eq([2, 9, 12])
    end

    it 'refuses a top-level loop that declares nothing' do
      source = "RSpec.describe 'x' do\n  %i[a b].each do |x|\n    helper(x)\n  end\nend\n"
      expect { described_class.top_level_declarations(source) }.to raise_error(ArgumentError, /loop at/)
    end
  end

  describe '.split' do
    it 'keeps every item exactly once across balanced buckets, deterministically' do
      items = (1..20).map { |weight| described_class::Declaration.new(line: weight, weight: weight, randomized: false) }
      groups = described_class.split(items, 4)

      expect(groups.flatten.map(&:line).sort).to eq((1..20).to_a)
      totals = groups.map { |group| group.sum(&:weight) }
      expect(totals.max - totals.min).to be <= 20
      expect(described_class.split(items, 4)).to eq(groups)
    end

    it 'never produces an empty bucket' do
      items = (1..2).map { |weight| described_class::Declaration.new(line: weight, weight: weight, randomized: false) }
      expect(described_class.split(items, 4).size).to eq(2)
    end
  end

  describe '.plan' do
    it 'splits the harness into one line-filtered process per bucket and one process per seed' do
      jobs = described_class.plan([described_class::HARNESS], buckets: 3, seeds: '1,2', harness_source: harness_source)
      seeds, buckets = jobs.partition { |job| job.env.key?('WOODS_DIFF_SEEDS') }

      expect(seeds.map { |job| job.env.fetch('WOODS_DIFF_SEEDS') }).to contain_exactly('1', '2')
      expect(buckets.size).to eq(3)
      declarations = described_class.top_level_declarations(harness_source)
      selected = buckets.flat_map { |job| job.arguments.first.split(':').drop(1).map(&:to_i) }
      expect(selected.sort).to eq(declarations.reject(&:randomized).map(&:line).sort)
      randomized = declarations.find(&:randomized).line
      expect(seeds.map(&:arguments)).to all(eq(["#{described_class::HARNESS}:#{randomized}"]))
    end

    # The line filters are derived from the harness's text, so a declaration
    # the parser misreads (a second example inside a top-level loop, a
    # top-level form it does not recognise) would drop examples from CI
    # without a failure. RSpec's own dry run is the oracle: the processes
    # together must declare the whole file's examples, each exactly once.
    it 'selects every example of the harness exactly once across its processes, by RSpec dry run' do
      seeds = '1,2,3'
      dry_run = lambda do |arguments, env, out|
        command = [RbConfig.ruby, File.join(described_class::ROOT, 'bin', 'rspec'), '--options', File::NULL,
                   '--require', 'spec_helper', '--dry-run', '--format', 'json', '--out', out, *arguments]
        output, status = Open3.capture2e({ 'WOODS_RUN_BOOTED_APP' => '1', 'WOODS_DIFF_SEEDS' => seeds }.merge(env),
                                         *command, chdir: described_class::ROOT)
        raise "dry run failed for #{arguments.join(' ')}:\n#{output}" unless status.success?

        JSON.parse(File.read(out, encoding: 'UTF-8')).fetch('examples').map { |example| example['full_description'] }
      end

      Dir.mktmpdir do |dir|
        whole = dry_run.call([described_class::HARNESS], {}, File.join(dir, 'whole.json'))
        jobs = described_class.plan([described_class::HARNESS], buckets: 4, seeds: seeds,
                                                                harness_source: harness_source)
        split = jobs.each_with_index.flat_map do |job, index|
          dry_run.call(job.arguments, job.env, File.join(dir, "#{index}.json"))
        end

        expect(whole).not_to be_empty
        expect(split.tally.select { |_, count| count > 1 }.keys).to be_empty
        expect(split.sort).to eq(whole.sort)
      end
    end

    it 'keeps the file sets that shared a process together and runs every other file alone' do
      files = described_class::SHARED_GROUPS.first + %w[spec/integration/declaration_identity_spec.rb
                                                        spec/integration/watch_daemon_spec.rb]
      jobs = described_class.plan(files, buckets: 2, harness_source: harness_source)

      expect(jobs.map(&:arguments)).to contain_exactly(described_class::SHARED_GROUPS.first,
                                                       ['spec/integration/declaration_identity_spec.rb'],
                                                       ['spec/integration/watch_daemon_spec.rb'])
      expect(jobs.first.arguments).to eq(described_class::SHARED_GROUPS.first)
    end

    it 'runs a shared group member alone when its partners were not given' do
      jobs = described_class.plan(described_class::SHARED_GROUPS.last.first(1), buckets: 2,
                                                                                harness_source: harness_source)
      expect(jobs.map(&:arguments)).to eq([described_class::SHARED_GROUPS.last.first(1)])
    end

    it 'refuses a file that does not exist' do
      expect { described_class.plan(['spec/integration/no_such_spec.rb'], buckets: 1, harness_source: harness_source) }
        .to raise_error(ArgumentError, /no such spec file/)
    end
  end

  describe '.environment' do
    it 'gives each process its own scratch path and number, with the GC tuning unless opted out' do
      job = described_class::Job.new(label: 'x', arguments: [], env: { 'WOODS_DIFF_SEEDS' => '2' }, weight: 1)
      env = described_class.environment(job, 3, '/tmp/x')

      expect(env).to include('TEST_ENV_NUMBER' => '3', 'TMPDIR' => '/tmp/x', 'WOODS_DIFF_SEEDS' => '2')
      expect(env).to include(described_class::GC_TUNING)
      ENV['WOODS_BOOTED_GC_TUNING'] = '0'
      expect(described_class.environment(job, 3, '/tmp/x').keys).not_to include(*described_class::GC_TUNING.keys)
    ensure
      ENV.delete('WOODS_BOOTED_GC_TUNING')
    end
  end

  describe 'ci.yml' do
    it 'runs every booted file of the job through the runner, each shared group complete' do
      run = step('Run booted-app extraction').fetch('run')
      files = run.split.grep(%r{\Aspec/})

      expect(run).to start_with('bundle exec ruby script/parallel-booted')
      expect(files).to eq(files.uniq)
      files.each do |file|
        expect(File).to be_file(File.join(described_class::ROOT, file))
        expect(File.read(File.join(described_class::ROOT, file), encoding: 'UTF-8')).to include(':booted_app')
      end
      described_class::SHARED_GROUPS.each { |group| expect(files).to include(*group) }
      expect(files).not_to include(described_class::HARNESS)
    end

    it 'runs the harness through the runner, which splits it per core and per seed' do
      harness = step('Run incremental equivalence harness')
      expect(harness.fetch('run')).to eq("bundle exec ruby script/parallel-booted #{described_class::HARNESS}")
    end
  end
end
