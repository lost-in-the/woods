# frozen_string_literal: true

require 'logger'
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
require 'woods/resilience/index_validator'

def write_fixture(root, relative, source)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source)
  path
end

def check!(label)
  raise label unless yield
end

Dir.mktmpdir('woods_once_loader') do |root|
  write_fixture(root, 'config/database.yml', JSON.generate(Rails.env => { adapter: 'sqlite3', database: ':memory:' }))
  write_fixture(root, 'app/controllers/application_controller.rb',
                'class ApplicationController < ActionController::API; end')
  write_fixture(root, 'app/services/main_box.rb', 'class MainBox; end')
  write_fixture(root, 'app/services/main_box/api.rb', "class MainBox\n  class Api\n  end\nend\n")
  write_fixture(root, 'lib/once_kit.rb', 'module OnceKit; end')
  write_fixture(root, 'lib/once_kit/container.rb', "module OnceKit\n  class Container\n  end\nend\n")
  %w[API Parser Renderer].each do |name|
    write_fixture(root, "lib/once_kit/container/#{name.downcase}.rb", <<~RUBY)
      module OnceKit
        class Container
          class #{name}
            def self.value
              :baseline
            end
          end
        end
      end
    RUBY
  end
  write_fixture(root, 'lib/actions/once_collapsed.rb', 'class OnceCollapsed; end')
  write_fixture(root, 'lib/namespaced/tool.rb', "module OnceNamespace\n  class Tool\n  end\nend\n")
  ignored = write_fixture(root, 'lib/ignored/control.rb', 'class IgnoredOnceControl; end')
  Object.const_set(:OnceNamespace, Module.new)

  app = Class.new(Rails::Application)
  Object.const_set(:OnceLoaderApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'once-loader-test'
  app.config.logger = Logger.new(IO::NULL)
  app.config.autoloader = :zeitwerk if app.config.respond_to?(:autoloader=)
  uses_autoload_lib_once = app.config.respond_to?(:autoload_lib_once)
  if uses_autoload_lib_once
    app.config.autoload_lib_once(ignore: %w[tasks ignored])
  else
    # The same boot contract runs on the older Rails matrix rows too.
    app.config.autoload_once_paths << File.join(root, 'lib')
    app.config.eager_load_paths << File.join(root, 'lib')
  end
  app.initializer('once_loader_fixture', before: :setup_once_autoloader) do
    once = Rails.autoloaders.once
    once.inflector = Zeitwerk::Inflector.new
    once.inflector.inflect('api' => 'API')
    once.ignore(File.join(root, 'lib/ignored'))
    once.collapse(File.join(root, 'lib/actions'))
    once.push_dir(File.join(root, 'lib/namespaced'), namespace: OnceNamespace)
  end
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  Rails.application.eager_load!

  scanner = Object.new.extend(Woods::Extractors::SourceNesting)
  check!('once owns lib') { Rails.autoloaders.once.dirs.include?(File.join(root, 'lib')) }
  check!('main does not own lib') { !Rails.autoloaders.main.dirs.include?(File.join(root, 'lib')) }
  check!('ignored path remains unmanaged') { scanner.governed_class_name(ignored, File.read(ignored)).nil? }
  check!('ignored path is not autoloaded') { !Object.const_defined?(:IgnoredOnceControl, false) }
  check!('once acronym runtime') { OnceKit::Container::API.value == :baseline }
  check!('main inflection unchanged') { MainBox::Api.is_a?(Class) && !MainBox.const_defined?(:API, false) }
  check!('root namespace runtime') { OnceNamespace::Tool.is_a?(Class) }
  check!('collapsed directory runtime') { OnceCollapsed.is_a?(Class) }

  Woods.configuration.concurrent_extraction = false
  output = File.join(root, 'tmp/woods')
  Woods::Extractor.new(output_dir: output).extract_all
  reader = Woods::MCP::IndexReader.new(output)
  expected = {
    'OnceKit::Container::API' => 'lib/once_kit/container/api.rb',
    'OnceKit::Container::Parser' => 'lib/once_kit/container/parser.rb',
    'OnceKit::Container::Renderer' => 'lib/once_kit/container/renderer.rb',
    'OnceNamespace::Tool' => 'lib/namespaced/tool.rb',
    'OnceCollapsed' => 'lib/actions/once_collapsed.rb'
  }
  expected.each do |identifier, path|
    check!("published #{identifier}") { reader.find_unit(identifier, type: 'lib')&.fetch('file_path') == path }
  end
  check!('published main control') { reader.find_unit('MainBox::Api', type: 'service') }

  changed = expected.fetch('OnceKit::Container::Parser')
  file = File.join(root, changed)
  File.write(file, File.read(file).sub(':baseline', ':changed'))
  Woods::Extractor.new(output_dir: output).extract_changed([changed])
  incremental = Woods::MCP::IndexReader.new(output)
  check!('incremental source update') do
    incremental.find_unit('OnceKit::Container::Parser', type: 'lib').fetch('source_code').include?(':changed')
  end
  full_output = File.join(root, 'tmp/woods-full')
  Woods::Extractor.new(output_dir: full_output).extract_all
  full = Woods::MCP::IndexReader.new(full_output)
  expected.each_key do |identifier|
    check!("full/incremental equivalence #{identifier}") do
      incremental.find_unit(identifier, type: 'lib').except('extracted_at') ==
        full.find_unit(identifier, type: 'lib').except('extracted_at')
    end
  end
  report = Woods::Resilience::IndexValidator.new(index_dir: output, app_root: root).validate
  check!("invalid published index: #{report.errors}") { report.valid? }
  puts JSON.generate(rails: Rails.version, autoload_lib_once: uses_autoload_lib_once,
                     woods: Woods::VERSION,
                     loaded_woods: $LOADED_FEATURES.find { |path| path.end_with?('/lib/woods.rb') },
                     identifiers: expected.keys, valid: true, incremental_equivalent: true)
end
