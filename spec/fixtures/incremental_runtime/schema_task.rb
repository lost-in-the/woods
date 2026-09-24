# frozen_string_literal: true

# Each invocation boots a new Rails process against the same application/index.
ENV['RAILS_ENV'] = 'test'
root, phase, changed_input = ARGV
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'rake'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/extractor'
require 'woods/mcp/index_reader'
require_relative '../../support/index_comparison'

database = File.join(root, 'database.sqlite3')
FileUtils.mkdir_p([File.join(root, 'config'), File.join(root, 'app/models'), File.join(root, 'db')])
File.write(File.join(root, 'config/database.yml'), JSON.generate('test' => { adapter: 'sqlite3', database: database }))
File.write(File.join(root, 'config/application.rb'), "# runtime phase #{phase}\n")
File.write(File.join(root, 'app/models/post.rb'), 'class Post < ActiveRecord::Base; end')
FileUtils.mkdir_p(File.dirname(File.join(root, changed_input)))
File.write(File.join(root, changed_input), "# schema phase #{phase}\n")
app = Class.new(Rails::Application)
Object.const_set(:SchemaTaskApplication, app)
app.config.root = root
app.config.api_only = true
app.config.eager_load = false
app.config.secret_key_base = 'schema-task-fixture'
app.config.time_zone = phase == 'baseline' ? 'UTC' : 'Hawaii'
app.config.logger = Logger.new(IO::NULL)
app.initialize!
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: database)
ActiveRecord::Schema.verbose = false
if phase == 'baseline'
  ActiveRecord::Schema.define { create_table(:posts) { |table| table.string :title } }
else
  ActiveRecord::Schema.define { add_column :posts, :slug, :string }
end
Woods.configure do |config|
  config.concurrent_extraction = false
  config.enable_snapshots = false
  config.include_framework_sources = false
end
output = File.join(root, 'tmp/index')
ENV['WOODS_OUTPUT'] = output
ENV['WOODS_IGNORE_WATCH'] = '1'
ENV['CHANGED_FILES'] = [changed_input, ('app/models/post.rb' if phase == 'mixed')].compact.join(',')
Rake::Task.define_task(:environment)
load File.expand_path('../../../lib/tasks/woods.rake', __dir__)
Rake::Task[phase == 'baseline' ? 'woods:extract' : 'woods:incremental'].invoke
if phase != 'baseline'
  Dir.mktmpdir('schema_oracle') do |oracle|
    Woods::Extractor.new(output_dir: oracle).extract_all
    differences = IndexComparison.differences(output, oracle)
    raise differences.inspect unless differences.empty?
  end
  reader = Woods::MCP::IndexReader.new(output)
  post = reader.find_unit('Post', type: 'model')
  raise 'stale model schema header' unless post.fetch('source_code').include?('slug')

  profile = reader.find_unit('BehavioralProfile', type: 'configuration')
  raise 'stale profile' unless profile.dig('metadata', 'behavior_flags', 'time_zone') == 'Hawaii'
  raise 'phantom configuration unit' if reader.find_unit('application.rb', type: 'configuration')
end
puts JSON.generate('generation' => Woods::Generation.new(output_dir: output).current.number)
