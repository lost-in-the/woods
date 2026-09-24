# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require 'woods/retrieval/source_evidence'
require_relative '../../support/index_comparison'

root, phase, loader = ARGV
raise 'root and phase required' unless root && phase

def write(root, path, content)
  file = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(file))
  File.write(file, content)
end

def verify(label)
  raise label unless yield
end

if phase == 'baseline'
  write(root, 'config/database.yml', JSON.generate('test' => { adapter: 'sqlite3', database: ':memory:' }))
  write(root, 'app/controllers/application_controller.rb', 'class ApplicationController < ActionController::API; end')
  write(root, 'app/services/fixture_dependency.rb', 'class FixtureDependency; def call; :before; end; end')
  write(root, 'lib/library_fixture.rb', "module LibraryFixture\n  def self.first; :one; end\nend\n")
  write(root, 'lib/extensions/version.rb',
        "module LibraryFixture\n  VERSION = 'é'\n  def self.second; FixtureDependency; end\nend\n")
  [['init', '-q'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.invalid'],
   ['add', 'config', 'app', 'lib/library_fixture.rb'], ['commit', '-qm', 'First contributor'],
   ['add', 'lib/extensions/version.rb'], ['commit', '-qm', 'Second contributor']].each do |args|
    raise 'git failed' unless system('git', '-C', root, *args, out: File::NULL, err: File::NULL)
  end
  %w[lib/library_fixture.rb lib/extensions/version.rb].each do |path|
    File.write(File.join(root, path), "#{File.read(File.join(root, path))}# shared commit\n")
  end
  [['add', 'lib'], ['commit', '-qm', 'Both contributors']].each do |args|
    raise 'git failed' unless system('git', '-C', root, *args, out: File::NULL, err: File::NULL)
  end
end
changed = case phase
          when 'edit'
            path = 'lib/extensions/version.rb'
            File.write(File.join(root, path), File.read(File.join(root, path)).sub("'é'", "'é2'"))
            [path]
          when 'dependency'
            path = 'app/services/fixture_dependency.rb'
            File.write(File.join(root, path), File.read(File.join(root, path)).sub(':before', ':after'))
            [path]
          when 'delete'
            File.delete(File.join(root, 'lib/library_fixture.rb'))
            ['lib/library_fixture.rb']
          when 'restore'
            write(root, 'lib/library_fixture.rb', "module LibraryFixture\n  def self.first; :one; end\nend\n")
            ['lib/library_fixture.rb']
          when 'delete_primary'
            File.delete(File.join(root, 'lib/extensions/version.rb'))
            ['lib/extensions/version.rb']
          else []
          end
app = Class.new(Rails::Application)
Object.const_set(:LibraryContributorApplication, app)
app.config.root = root
app.config.api_only = true
app.config.eager_load = false
app.config.secret_key_base = 'library-contributor-fixture'
app.config.logger = Logger.new(IO::NULL)
app.config.autoload_lib_once(ignore: %w[extensions]) if loader == 'once'
app.initialize!
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
Rails.application.eager_load!
# Fixture loading is explicit; extraction itself must never load unmanaged libraries.
Dir.glob('**/*.rb', base: File.join(root, 'lib')).sort.each { |file| require File.join(root, 'lib', file) }
Woods.configure do |config|
  config.concurrent_extraction = false
  config.enable_snapshots = false
  config.include_framework_sources = false
end
output = File.join(root, 'tmp/index')
runner = Woods::Extractor.new(output_dir: output)
if phase == 'failure'
  pointer = File.binread(File.join(output, 'generation.json'))
  failing_path = File.join(root, 'lib/library_fixture.rb')
  fault = Module.new do
    define_method(:read) do |path, *args, **options, &block|
      raise Errno::EACCES if path.to_s == failing_path

      super(path, *args, **options, &block)
    end
  end
  File.singleton_class.prepend(fault)
  refused = false
  begin
    runner.refresh(:libs)
    runner.raise_on_publication_failure!
  rescue Woods::ExtractionError
    refused = true
  end
  verify('failed contributor refresh preserves prior generation') do
    refused && File.binread(File.join(output, 'generation.json')) == pointer
  end
  puts JSON.generate(phase: phase, identifier: 'LibraryFixture')
  exit
end
if phase == 'baseline'
  runner.extract_all
elsif phase == 'refresh'
  runner.refresh(:libs)
else
  runner.extract_changed(changed)
end
runner.raise_on_publication_failure!
unit = Woods::MCP::IndexReader.new(output).find_unit('LibraryFixture', type: 'lib')
verify('published library') { unit }
verify('secondary references retained') do
  unit['dependencies'].any? { |edge| edge['target'] == 'FixtureDependency' && edge['via'] == 'code_reference' } ==
    (phase != 'delete_primary')
end
unless %w[delete delete_primary].include?(phase)
  verify('all fragments retained') do
    unit['source_code'].include?('def self.first') && unit['source_code'].include?('def self.second')
  end
  records = Woods::SourceContributors.records(unit)
  verify('physical provenance') do
    records.size == 2 && records.all? do |record|
      record['git'] && record['source_sha256']
    end
  end
  verify('no arbitrary aggregate git') { !unit['metadata'].key?('git') }
  verify('individual and shared commits remain per-file facts') do
    histories = records.map { |record| record.fetch('git') }
    histories.all? { |git| git['commit_count'] == 2 } &&
      histories.map { |git| git.fetch('recent_commits').first.fetch('sha') }.uniq.one? &&
      histories.map { |git| git.fetch('recent_commits').last.fetch('sha') }.uniq.size == 2
  end
  secondary = records.find { |record| record['file_path'] == 'lib/extensions/version.rb' }
  selector = Woods::Retrieval::SourceEvidence.new(unit: unit, query: 'second')
  evidence = selector.render(mode: 'compact', budget: 3000, counter: ->(text) { text.length / 4 })
  verify('physical evidence points to contributor') do
    evidence.provenance[:spans].any? do |span|
      span[:name] == 'second' && span.dig(:physical_location, :file_path) == secondary['file_path']
    end
  end
end
Dir.mktmpdir('library-oracle') do |oracle|
  full = Woods::Extractor.new(output_dir: oracle)
  full.extract_all
  full.raise_on_publication_failure!
  differences = IndexComparison.differences(output, oracle)
  raise "#{phase}: #{differences.inspect}" unless differences.empty?
end
puts JSON.generate(phase: phase, identifier: unit['identifier'],
                   generation: Woods::Generation.new(output_dir: output).current)
