# frozen_string_literal: true

if ENV['WOODS_TEST_CONSOLE_LAUNCHER'] == 'rake'
  require 'rake'
  load File.expand_path('../../../lib/tasks/woods.rake', __dir__)
  Rake::Task.define_task(:environment) { require_relative 'booted_console_app' }
  Rake::Task['woods:console'].invoke
else
  require_relative 'booted_console_app'

  load File.expand_path('../../../exe/woods-console', __dir__)
end
