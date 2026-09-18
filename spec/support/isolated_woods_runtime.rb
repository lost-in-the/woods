# frozen_string_literal: true

# Specs invoking the orchestrator need its normal host time extensions and a
# configured Woods entry point. Load them before example setup, then isolate
# mutable configuration without changing narrow-load behavior for other specs.
RSpec.shared_context 'isolated Woods runtime' do
  around do |example|
    require 'woods'
    require 'active_support'
    require 'active_support/time'

    previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    example.run
  ensure
    Woods.configuration = previous
  end
end
