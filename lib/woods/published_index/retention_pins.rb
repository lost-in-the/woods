# frozen_string_literal: true

require_relative '../generation_pins'

module Woods
  class PublishedIndex
    # Generation numbers held by persistent retention pins (`woods:pin[N]`),
    # ascending. Pins are operational state beside the payloads, not part of
    # any generation, so this reads no payload and takes no retention lock.
    #
    # The set is reported as recorded: a pin whose payload was removed outside
    # Woods retention (`woods:clean`, manual deletion) stays listed until it is
    # released. Intersect with {.available_generations} for readable pinned
    # payloads.
    #
    # @param index_dir [String, Pathname]
    # @return [Array<Integer>] empty when no pin was ever recorded
    # @raise [IOError] when the pin state is unreadable or malformed; never
    #   reported as "no pins", which would hide retention protection
    def self.retention_pins(index_dir)
      Woods::GenerationPins.new(index_dir).pins
    end
  end
end
