# frozen_string_literal: true

module Woods
  module Checks
    # Turns "which two generations should `woods:check:moved_messages`
    # compare" into a pair of numbers, given the generations a
    # {Woods::PublishedIndex} currently has published (#280 / M14).
    #
    # A pure function over its arguments: it never touches the filesystem or
    # opens an index. `to` defaults to the newest published generation,
    # `from` defaults to the newest one strictly older than `to`. Either side
    # given explicitly is used as-is (converted with `Integer()`, so rake's
    # string arguments work); explicit values are not checked against
    # +available+ here, {Woods::PublishedIndex.new} already raises a clear
    # `ArgumentError` for a generation that is not published.
    module GenerationResolution
      # @param available [Array<Integer>] published generation numbers, ascending
      # @param from [String, Integer, nil] explicit older generation
      # @param to [String, Integer, nil] explicit newer generation
      # @return [Array(Integer, Integer), nil] `[from, to]`, or nil when there
      #   are not two generations to compare (fewer than two retained, and
      #   neither side was given explicitly)
      def self.call(available, from: nil, to: nil)
        to_number = to ? Integer(to) : available.last
        return nil if to_number.nil?

        from_number = from ? Integer(from) : available.select { |number| number < to_number }.max
        return nil if from_number.nil?

        [from_number, to_number]
      end
    end
  end
end
