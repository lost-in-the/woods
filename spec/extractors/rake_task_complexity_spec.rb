# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/rake_source_parser'
require 'woods/extractors/rake_runtime_index'
require 'woods/extractors/rake_task_catalog'
require 'woods/extractors/rake_task_paths'

# The rake readers match no regular expressions: they walk a Prism tree and
# compare strings. These inputs hold the walk, the catalog and the path
# grammar to linear time, and pin what pathological nesting does.
RSpec.describe 'rake task extraction on adversarial input' do
  around do |example|
    previous = Regexp.respond_to?(:timeout) ? Regexp.timeout : nil
    Regexp.timeout = 1 if Regexp.respond_to?(:timeout=)
    Timeout.timeout(5) { example.run }
  ensure
    Regexp.timeout = previous if Regexp.respond_to?(:timeout=)
  end

  let(:parser) { Woods::Extractors::RakeSourceParser }

  def catalog_for(task_source, support_source = '')
    Woods::Extractors::RakeTaskCatalog.new(
      task_files: { '/app/lib/tasks/a.rake' => parser.parse(task_source) },
      support_files: { 'rake/lib/a.rb' => parser.parse(support_source) },
      runtime: Woods::Extractors::RakeRuntimeIndex.new(nil)
    )
  end

  it 'parses 50,000 task definitions' do
    expect(parser.parse("task :a\n" * 50_000).definitions.size).to eq(50_000)
  end

  it 'parses 50,000 descriptions that never reach a task' do
    expect(parser.parse("desc 'x'\n" * 50_000).definitions).to eq([])
  end

  it 'passes over 10,000 near-matches' do
    source = "taskx :a\ntasks a: :b\nRake::Task['a'].enhances\nRake::Tasks['a'].enhance\nnamespace_for :a\n" * 10_000
    result = parser.parse(source)

    expect([result.definitions, result.enhancements]).to eq([[], []])
  end

  it 'reads one command with 50,000 interpolations' do
    definition = parser.parse("task :a do\n  sh \"#{"\#{x} " * 50_000}\"\nend\n").definitions.first

    expect(definition[:facts][:calls].first[:command].length).to eq(250_000)
  end

  it 'reads a 10,000-segment constant path as one reference' do
    path = (['A'] * 10_000).join('::')

    expect(parser.parse("task :a do\n  #{path}\nend\n").definitions.first[:facts][:constants]).to eq([path])
  end

  it 'reads a 10,000-segment path under a lowercase head without recursing' do
    facts = parser.parse("task :a do\n  a#{'::B' * 10_000}\nend\n").definitions.first[:facts]

    expect(facts[:constants]).to eq([])
    expect(facts[:calls].map { |call| call[:name] }).to eq(['a'])
  end

  it 'reads a chain of 10,000 calls without recursing' do
    result = parser.parse("task :a do\n  widgets#{'.next' * 10_000}\nend\nwidgets#{'.next' * 10_000}\n")

    expect(result.definitions.size).to eq(1)
    expect(result.facts[:calls].map { |call| call[:name] }.uniq).to eq(%w[task widgets])
  end

  it 'reads 10,000 nested call arguments without recursing' do
    nested = "#{'f(' * 10_000}1#{')' * 10_000}"

    expect { parser.parse("task :a do\n  #{nested}\nend\n#{nested}\n") }.not_to raise_error
  end

  it 'groups 50,000 definitions of one task' do
    catalog = catalog_for("task a: :b\n" * 50_000)

    expect(catalog.names).to eq(['a'])
    expect(catalog.records_for('a').size).to eq(50_000)
  end

  it 'follows a chain of 10,000 helper methods to the one that shells out' do
    chain = Array.new(10_000) { |i| "def step_#{i}(c)\n  step_#{i + 1}(c)\nend\n" }.join
    catalog = catalog_for("task :a do\n  step_0 'make'\nend\n", "#{chain}def step_10000(c)\n  sh c\nend\n")
    facts = parser.parse("task :a do\n  step_0 'make'\nend\n").definitions.first[:facts]

    expect(catalog.shell_commands(facts)).to eq(['make'])
  end

  it 'resolves 10,000 prerequisites inside a namespace' do
    source = "namespace :n do\n  task :b\n  task a: %i[#{(['b'] * 10_000).join(' ')}]\nend\n"
    catalog = catalog_for(source)
    record = catalog.records_for('n:a').first

    expect(record[:prerequisites].map { |name| catalog.resolve(name, record[:namespace]) }.uniq).to eq(['n:b'])
  end

  it 'validates and matches a 50,000-segment path' do
    paths = Woods::Extractors::RakeTaskPaths
    deep = "#{(['d'] * 50_000).join('/')}/**/*.rake"

    expect(paths.validate!([deep])).to eq([deep])
    expect(paths.task_file?("#{(['d'] * 50_000).join('/')}/x/y.rake", [deep])).to be(true)
    expect(paths.task_file?("#{(['d'] * 49_999).join('/')}/x/y.rake", [deep])).to be(false)
  end

  it 'reads 10,000 nested namespaces without recursing' do
    source = "#{"namespace :a do\n" * 10_000}task :x\n#{"end\n" * 10_000}"

    expect(parser.parse(source).definitions.size).to eq(1)
  end
end
