# frozen_string_literal: true

module CodebaseIndex
  module Formatting
    # Abstract base class for formatting adapters.
    #
    # Each adapter transforms an AssembledContext into a format suitable for
    # a specific LLM or output target. Subclasses must implement {#format}.
    #
    # @abstract Subclass and override {#format} to implement.
    #
    # @example
    #   class MyAdapter < Base
    #     def format(assembled_context)
    #       "Content: #{assembled_context.context}"
    #     end
    #   end
    #
    class Base
      # Format an assembled context for output.
      #
      # @param _assembled_context [CodebaseIndex::Retrieval::AssembledContext]
      # @return [String] Formatted output
      # @raise [NotImplementedError] if not overridden by subclass
      def format(_assembled_context)
        raise NotImplementedError, "#{self.class}#format must be implemented"
      end
    end
  end
end
