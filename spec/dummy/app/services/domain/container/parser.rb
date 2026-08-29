# frozen_string_literal: true

# Wrapped in class namespaces, for finding G-1. The source-derived identifier
# used to stop at the first class declaration and index the wrapper
# (Domain::Container), colliding with every sibling file under it. The booted
# lane pins the child constant on every supported Rails version.
module Domain
  class Container
    class Parser
      def call(input)
        input.parse
      end
    end
  end
end
