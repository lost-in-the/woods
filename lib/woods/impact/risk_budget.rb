# frozen_string_literal: true

module Woods
  module Impact
    # Shared endpoint budget for inspected risk units and published records.
    class RiskBudget
      # @param limit [Integer]
      def initialize(limit)
        @remaining = limit
      end

      # @param count [Integer]
      # @return [void]
      def consume(count = 1)
        if count > @remaining
          @remaining = 0
          throw :risk_budget, 'risk_record_budget'
        end
        @remaining -= count
      end
    end
  end
end
