# frozen_string_literal: true

require_relative 'cost_model/provider_pricing'
require_relative 'cost_model/embedding_cost'
require_relative 'cost_model/storage_cost'
require_relative 'cost_model/estimator'

module CodebaseIndex
  # Cost modeling for embedding, storage, and query costs across different
  # backend configurations. Based on the cost analysis in BACKEND_MATRIX.md.
  #
  # @example
  #   estimate = CodebaseIndex::CostModel::Estimator.new(
  #     units: 500,
  #     embedding_provider: :openai_small
  #   )
  #   estimate.full_index_cost    # => 0.011
  #   estimate.monthly_query_cost # => 0.006
  #
  module CostModel
  end
end
