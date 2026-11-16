# frozen_string_literal: true

require_relative '../../lib/woods/console/credential_scanner_registry'

# Keep GC stress and any native-runtime failure outside the RSpec process.
Process.setrlimit(Process::RLIMIT_CORE, 0, 0) if defined?(Process::RLIMIT_CORE)
Thread.new do
  sleep 30
  exit! 124
end

scanner_class = Class.new do
  attr_reader :index

  def replace_index!(index)
    @index = index
  end
end
registry = Woods::Console::CredentialScannerRegistry.new
live = registry.register { scanner_class.new }

10.times do |index|
  Thread.new do
    100.times { registry.register { scanner_class.new } }
    nil
  end.join
  GC.stress = true
  registry.rebuild { index }
  GC.stress = false
  raise 'live scanner was not refreshed' unless live.index == index
end

puts 'live scanners refreshed'
