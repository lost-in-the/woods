# frozen_string_literal: true

require 'rspec'
require 'active_support/core_ext/string/inflections'
require 'codebase_index/extracted_unit'
require 'codebase_index/dependency_graph'
require 'codebase_index/graph_analyzer'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed
end
