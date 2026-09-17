# frozen_string_literal: true

# Runs in a fresh process so no earlier extractor can load the lazy route set.
require 'bundler/setup'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'active_job/railtie'
require 'woods'
require 'woods/extractor'
require 'json'

app_root, output_dir, mode = ARGV
ENV['WOODS_DUMMY_DB'] = File.join(app_root, 'test.sqlite3')
class LazyRoutesApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.secret_key_base = 'woods-lazy-routes-test'
end
LazyRoutesApplication.config.root = app_root
LazyRoutesApplication.initialize!
ActiveRecord::Base.establish_connection(:test)
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :title
    t.integer :status, default: 0
    t.timestamps
  end
  create_table :comments, force: true do |t|
    t.references :post
    t.text :body
    t.timestamps
  end
end
Rails.application.eager_load!
Woods.configuration.concurrent_extraction = false
Woods.configuration.extract_navigation_edges = true
# Directly exercise initialization before any controller extractor runs.
if mode == 'probe'
  resolver = Woods::Extractors::ViewTemplateExtractor.new
  abort 'Missing lazy route helper posts_path' unless resolver.resolve_route_helper('posts_path')
  exit
end
extractor = Woods::Extractor.new(output_dir: output_dir)
if mode == 'incremental'
  extractor.extract_changed(['app/views/posts/index.html.erb'])
else
  extractor.extract_all
end
