# frozen_string_literal: true

module TraceKindFixture
  class Parent
    def run
      42
    end

    def self.run
      'singleton'
    end

    def invoke
      self.class.run
    end

    class << self
      def invoke
        run
      end
    end
  end

  class Child < Parent
  end

  module Factory
    def self.run
      :module_result
    end
  end
end
