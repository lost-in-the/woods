# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'rails'
require 'active_record/railtie'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'logger'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

# Model origin (#995) in a fresh Rails process. Each model's constant is first
# defined in a different kind of file:
#
# | Model                         | Defined first in                         | origin      |
# |-------------------------------|------------------------------------------|-------------|
# | Post                          | app/models/post.rb                       | app         |
# | CatalogKit::Listing           | an installed gem (`catalog_kit-0.3.0`)    | gem         |
# | CatalogKit::Item              | the same gem, reopened by app/models/…   | gem         |
# | VendoredRecord                | vendor/models/vendored_record.rb         | unknown     |
# | StrayRecord                   | a file outside the app and the bundle    | unknown     |
# | ActiveRecord::SchemaMigration | activerecord (a model before Rails 7.1)  | framework   |
#
# The gem and stray files load before the application initializes, as
# Bundler.require loads gems. The reopening loads after boot, as a decorator
# does: the gem already defines the constant, so the autoloader skips the file.
# Prints, per extraction mode, every model's origin and its file_path relative
# to a known root.

def write(path, source)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source)
  path
end

Dir.mktmpdir('woods_model_origin') do |base|
  root = File.join(base, 'app_root')
  gem_lib = File.join(base, 'bundle/ruby/3.3.0/gems/catalog_kit-0.3.0/lib')
  elsewhere = File.join(base, 'elsewhere')
  database = File.join(base, 'database.sqlite3')

  write(File.join(root, 'config/database.yml'), JSON.generate('test' => { adapter: 'sqlite3', database: database }))
  write(File.join(root, 'app/models/application_record.rb'), <<~RUBY)
    class ApplicationRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  RUBY
  post = write(File.join(root, 'app/models/post.rb'), "class Post < ApplicationRecord\nend\n")
  reopening = write(File.join(root, 'app/models/catalog_kit/item.rb'), <<~RUBY)
    class CatalogKit::Item
      def app_extension; end
    end
  RUBY
  write(File.join(gem_lib, 'catalog_kit.rb'), <<~RUBY)
    module CatalogKit
    end
    require_relative 'catalog_kit/listing'
    require_relative 'catalog_kit/item'
  RUBY
  write(File.join(gem_lib, 'catalog_kit/listing.rb'), "class CatalogKit::Listing < ActiveRecord::Base\nend\n")
  write(File.join(gem_lib, 'catalog_kit/item.rb'), "class CatalogKit::Item < ActiveRecord::Base\nend\n")
  vendored = write(File.join(root, 'vendor/models/vendored_record.rb'),
                   "class VendoredRecord < ActiveRecord::Base\nend\n")
  stray = write(File.join(elsewhere, 'stray_record.rb'), "class StrayRecord < ActiveRecord::Base\nend\n")

  require File.join(gem_lib, 'catalog_kit')
  require vendored
  require stray

  app = Class.new(Rails::Application)
  Object.const_set(:ModelOriginProbeApplication, app)
  app.config.root = root
  app.config.eager_load = false
  app.config.secret_key_base = 'model-origin-fixture'
  app.config.logger = Logger.new(IO::NULL)
  app.config.autoloader = :zeitwerk if app.config.respond_to?(:autoloader=)
  app.initialize!
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: database)
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    %i[posts listings items vendored_records stray_records].each { |table| create_table(table) }
  end
  if ActiveRecord.version < Gem::Version.new('7.1') && !(ActiveRecord::SchemaMigration < ActiveRecord::Base)
    raise 'expected SchemaMigration to be a framework model before Rails 7.1'
  end

  app.eager_load!
  load reopening
  raise 'the reopening did not apply' unless CatalogKit::Item.method_defined?(:app_extension)

  Woods.configure do |config|
    config.concurrent_extraction = false
    config.enable_snapshots = false
    config.include_framework_sources = false
  end

  relative = lambda do |path|
    { root => 'app_root', gem_lib => 'catalog_kit_gem', elsewhere => 'elsewhere' }.each do |dir, label|
      return "#{label}/#{path.delete_prefix("#{dir}/")}" if path.start_with?("#{dir}/")
    end
    path.include?('/gems/activerecord-') || path.include?('/activerecord/lib/') ? 'activerecord' : path
  end
  models = lambda do |output|
    payload = Woods::Generation.new(output_dir: output).payload_dir.to_s
    Dir[File.join(payload, 'models', '*.json')].reject { |file| File.basename(file) == '_index.json' }.to_h do |file|
      unit = JSON.parse(File.read(file))
      [unit['identifier'],
       { 'origin' => unit.dig('metadata', 'origin'), 'file_path' => relative.call(unit['file_path']) }]
    end.sort.to_h
  end
  oracle_differences = lambda do |output|
    Dir.mktmpdir('model_origin_oracle') do |oracle|
      Woods::Extractor.new(output_dir: oracle).extract_all
      IndexComparison.differences(output, oracle)
    end
  end

  output = File.join(base, 'index')
  runner = Woods::Extractor.new(output_dir: output)
  runner.extract_all
  full = models.call(output)

  [post, reopening].each { |path| File.write(path, "#{File.read(path)}# an ordinary edit\n") }
  runner.extract_changed([post, reopening])
  runner.raise_on_publication_failure!
  incremental = models.call(output)
  incremental_differences = oracle_differences.call(output)

  runner.refresh(:models)
  runner.raise_on_publication_failure!
  refreshed = models.call(output)
  refresh_differences = oracle_differences.call(output)

  puts JSON.generate(rails: Rails.version, full: full, incremental: incremental, refresh: refreshed,
                     incremental_differences: incremental_differences, refresh_differences: refresh_differences)
end
