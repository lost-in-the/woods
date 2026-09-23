# frozen_string_literal: true

module Woods
  module Storage
    # Counts local store entries without loading vectors or source bodies.
    # Counts describe records (including chunks), not canonical unit coverage.
    module LocalCorpusStats
      module_function

      # @param types [Array<String, Symbol, nil>] one type per live entry
      # @return [Hash] total, known types, and entries without a usable type
      def from_types(types)
        from_counts(types.tally)
      end

      # @param counts [Hash] locally grouped type => entry counts
      # @return [Hash] entry counts with unknown types kept separate
      def from_counts(counts)
        by_type = Hash.new(0)
        untyped = 0
        counts.each do |type, count|
          if type.nil? || type.to_s.strip.empty?
            untyped += count
          else
            by_type[type.to_s] += count
          end
        end
        { count: by_type.values.sum + untyped, by_type: by_type.sort.to_h, untyped_count: untyped }
      end
    end
  end
end
