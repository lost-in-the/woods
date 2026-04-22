# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    minimum_coverage 88
  end
end

require 'rspec'
require 'active_support/core_ext/string/inflections'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include ThreadHelpers

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed

  config.after(:each) do
    Woods::ModelNameCache.reset! if defined?(Woods::ModelNameCache) && Woods::ModelNameCache.respond_to?(:reset!)
  end
end
