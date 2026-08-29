# frozen_string_literal: true

# Sibling of app/services/domain/container/parser.rb under the same
# Domain::Container wrapper class: before finding G-1 both files indexed as
# Domain::Container and same-type dedup silently dropped one of them.
module Domain
  class Container
    class Renderer
      def call(template)
        template.render
      end
    end
  end
end
