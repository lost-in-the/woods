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
  config.console_mcp_http_enabled = ENV.fetch('WOODS_TEST_CONSOLE_HTTP', '1') == '1'
  config.console_mcp_token = ENV.fetch('WOODS_CONSOLE_MCP_TOKEN', 'console-mcp-spec-token-32-characters')
  config.console_embedded_read_tools = ENV.fetch('WOODS_CONSOLE_READ_TOOLS', '1') == '1'
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

if ENV['WOODS_TEST_CONSOLE_STDOUT_LOGGING'] == '1'
  # Install before the executable, as a host initializer would. The rake
  # entry point has already redirected stdout; runner has not done so yet.
  Rails.logger = Logger.new($stdout)
  ActiveRecord::Base.logger = Rails.logger
  ActiveSupport::Notifications.subscribe('sql.active_record') do |*, event|
    next unless event[:sql].include?('SELECT COUNT')

    puts 'woods-stdio-runtime-puts'
    IO.for_fd(1, autoclose: false).syswrite("woods-stdio-runtime-fd\n")
  end
  # Eager loading is also performed by the executable after capture.
  Rails.application.singleton_class.prepend(Module.new do
    def eager_load!
      Rails.logger.info('woods-stdio-boot-log')
      super
    end
  end)
end
