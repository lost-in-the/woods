# frozen_string_literal: true

require_relative 'booted_console_app'
require 'rackup'
require 'woods/console/rack_middleware'

stateless = !%w[0 false no].include?(
  ENV.fetch('WOODS_CONSOLE_HTTP_STATELESS', '1').strip.downcase
)
app = Woods::Console::RackMiddleware.new(
  ->(_env) { [404, { 'content-type' => 'text/plain' }, ['not found']] },
  path: '/mcp/console',
  embedded_read_tools: Woods.configuration.console_embedded_read_tools,
  stateless: stateless
)

Rackup::Handler.default.run(
  app,
  Host: ENV.fetch('HOST', '127.0.0.1'),
  Port: Integer(ENV.fetch('PORT', '9292'), 10)
)
