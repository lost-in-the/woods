# frozen_string_literal: true

module Woods
  module Embedding
    module Provider
      # Keeps an explicit API width request separate from the expected width
      # recorded in an index or discovered by a provider probe.
      module VectorConfiguration
        # @return [Integer, nil] explicitly requested API output width
        attr_reader :requested_dimensions

        # Non-probing width declaration, also used to validate cache entries.
        # @return [Integer, nil]
        def configured_dimensions
          @expected_dimensions || @requested_dimensions
        end

        private

        def configure_dimensions(dimensions:, expected_dimensions:)
          @requested_dimensions = normalize_dimensions(dimensions)
          @expected_dimensions = normalize_dimensions(expected_dimensions)
          return unless @requested_dimensions && @expected_dimensions
          return if @requested_dimensions == @expected_dimensions

          raise ArgumentError, 'requested dimensions must match the expected vector dimensions'
        end

        def normalize_dimensions(value)
          return if value.nil?

          dimensions = Integer(value)
          raise ArgumentError, "dimensions must be positive, got #{value.inspect}" unless dimensions.positive?

          dimensions
        end

        def validate_vectors!(vectors, expected_count:, provider:, indexes: nil)
          VectorValidation.validate!(
            vectors, expected_count: expected_count, provider: provider, indexes: indexes,
                     expected_dimensions: configured_dimensions || @observed_dimensions
          )
          @observed_dimensions ||= vectors.first&.size # rubocop:disable Naming/MemoizedInstanceVariableName
        end
      end
    end
  end
end
