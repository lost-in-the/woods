# frozen_string_literal: true

module CodebaseIndex
  module RubyAnalyzer
    # Shared helper for building fully qualified names from a name and namespace stack.
    module FqnBuilder
      private

      def build_fqn(name, namespace_stack)
        if namespace_stack.empty?
          name
        else
          "#{namespace_stack.join('::')}::#{name}"
        end
      end
    end
  end
end
