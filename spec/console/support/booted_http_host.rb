# frozen_string_literal: true

require_relative 'booted_console_app'
require 'rackup'

Rackup::Handler.default.run(
  Rails.application,
  Host: ENV.fetch('HOST', '127.0.0.1'),
  Port: Integer(ENV.fetch('PORT', '9292'), 10)
)
