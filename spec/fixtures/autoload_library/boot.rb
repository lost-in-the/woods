# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

def write(root, path, text)
  absolute = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(absolute))
  File.write(absolute, text)
  absolute
end

def assert_fact(report, name)
  raise name unless yield

  report << name
end

Dir.mktmpdir('woods_autoload_library') do |root|
  report = []
  write(root, 'config/database.yml', JSON.generate(Rails.env => { adapter: 'sqlite3', database: ':memory:' }))
  write(root, 'app/models/library_caller.rb', <<~RUBY)
    class LibraryCaller
      def call
        DormantLibrary.new.generate
      end
    end
  RUBY
  # This file must remain unexecuted, even when Rails eager-loads app/models.
  library_source = <<~RUBY
    raise 'reference resolution triggered an autoload'
    class DormantLibrary
      def generate = :token
    end
  RUBY
  library = write(root, 'lib/dormant_library.rb', library_source)
  app = Class.new(Rails::Application)
  Object.const_set(:AutoloadLibraryApplication, app)
  app.config.root = root
  app.config.api_only = true
  app.config.eager_load = false
  app.config.cache_classes = false
  app.config.secret_key_base = 'autoload-library-test'
  app.config.logger = Logger.new(IO::NULL)
  app.config.autoload_paths << File.join(root, 'lib')
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!
  assert_fact(report, 'library remains registered after Rails eager load') do
    Object.autoload?(:DormantLibrary, false) == library && !Object.autoload?(:LibraryCaller, false)
  end
  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end
  output = File.join(root, 'tmp/index')
  Woods::Extractor.new(output_dir: output).extract_all
  reader = Woods::MCP::IndexReader.new(output)
  edge = { 'type' => 'lib', 'target' => 'DormantLibrary', 'via' => 'code_reference' }
  assert_fact(report, 'forward reference to an unexecuted registered library') do
    reader.find_unit('LibraryCaller').fetch('dependencies').include?(edge) &&
      Object.autoload?(:DormantLibrary, false) == library
  end
  graph = JSON.parse(File.read(Woods::Generation.new(output_dir: output).payload_dir.join('dependency_graph.json')))
  assert_fact(report, 'reverse reference agrees with typed forward edge') do
    graph.fetch('reverse').fetch('DormantLibrary').include?('LibraryCaller') &&
      graph.fetch('reverse_via').fetch('DormantLibrary').any? do |entry|
        entry['source'] == 'LibraryCaller' && entry['source_type'] == 'poro' && entry['via'] == 'code_reference'
      end
  end
  compare = lambda do |label|
    Dir.mktmpdir('woods_autoload_oracle') do |oracle|
      Woods::Extractor.new(output_dir: oracle).extract_all
      assert_fact(report, label) { IndexComparison.differences(output, oracle).empty? }
    end
  end
  File.unlink(library)
  Rails.application.reloader.reload!
  Woods::Extractor.new(output_dir: output).extract_changed([library])
  assert_fact(report, 'target removal removes cached caller edge through a connected reader') do
    !reader.find_unit('LibraryCaller').fetch('dependencies').include?(edge) && reader.find_unit('DormantLibrary').nil?
  end
  compare.call('target removal full/incremental equivalence')
  File.write(library, library_source)
  Rails.application.reloader.reload!
  Woods::Extractor.new(output_dir: output).extract_changed([library])
  assert_fact(report, 'target creation resolves unchanged caller without executing the target') do
    reader.find_unit('LibraryCaller').fetch('dependencies').include?(edge) &&
      Object.autoload?(:DormantLibrary, false) == library
  end
  compare.call('target creation full/incremental equivalence')
  Woods::Extractor.new(output_dir: output).refresh(:libs)
  compare.call('library refresh full equivalence')
  assert_fact(report, 'autoload never executed') { Object.autoload?(:DormantLibrary, false) == library }
  puts JSON.generate(checks: report, rails: Rails.version)
end
