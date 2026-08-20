# frozen_string_literal: true

require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'active_job/railtie'
require 'woods'

root = File.expand_path('../../dummy', __dir__)

Woods.configuration = Woods::Configuration.new
Woods.configure do |config|
  config.console_mcp_enabled = true
  config.console_mcp_token = 'console-mcp-spec-token-32-characters'
  config.console_embedded_read_tools = true
  config.console_blocked_tables = %w[schema_migrations ar_internal_metadata]
end

app_class = Class.new(Rails::Application) do
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.consider_all_requests_local = true
end
Object.const_set(:WoodsConsoleMcpSpecApplication, app_class)
WoodsConsoleMcpSpecApplication.config.root = root
WoodsConsoleMcpSpecApplication.config.secret_key_base = 'woods-console-mcp-spec-secret'
WoodsConsoleMcpSpecApplication.initialize!

ActiveRecord::Base.establish_connection(:test)
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :posts, force: true do |table|
    table.string :title
    table.integer :status, default: 0
    table.timestamps
  end

  create_table :comments, force: true do |table|
    table.references :post
    table.text :body
    table.timestamps
  end
end

Rails.application.eager_load!
Post.create!(title: 'Console contract row', status: 1)

load File.expand_path('../../../exe/woods-console', __dir__)
