# frozen_string_literal: true

# Explicit namespace for finding G-1: the wrapper is a CLASS, so it needs its
# own file. A `container/` directory without `container.rb` is an implicit
# namespace to Zeitwerk, which pre-creates Domain::Container as a Module and
# makes `class Container` in the wrapped files a boot-time TypeError.
module Domain
  class Container
    def self.wrap(input)
      input
    end
  end
end
