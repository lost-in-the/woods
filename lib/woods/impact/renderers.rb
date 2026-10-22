# frozen_string_literal: true

require_relative 'renderers/markdown'
require_relative 'renderers/mermaid'

module Woods
  module Impact
    # Pure renderers over the shared versioned report; never query an index.
    module Renderers
      # @param report [Report, Hash] schema version 1 report
      # @return [String] bounded Markdown summary, including unknown coverage
      def self.markdown(report)
        Markdown.new(document(report)).render
      end

      # @param report [Report, Hash] schema version 1 report
      # @return [String] bounded Mermaid flowchart of recorded impact witnesses
      def self.mermaid(report)
        Mermaid.new(document(report)).render
      end

      def self.document(report)
        data = report.to_h
        valid = data.is_a?(Hash) && data['schema_version'] == 1 && envelope?(data) &&
                data['coverage'].is_a?(Hash) && %w[changed affected flows tables templates risks tests
                                                   unknowns].all? do |key|
                                                  data[key].is_a?(Array)
                                                end
        raise ArgumentError, 'Unsupported impact schema or report shape' unless valid

        data
      end
      private_class_method :document

      def self.envelope?(data)
        return data['range'].is_a?(Hash) unless data.dig('parameters', 'mode') == 'focus'

        data['range'].nil? && data['endpoint'].is_a?(Hash) && data['focus'].is_a?(Array) && data['changed'] == []
      end
      private_class_method :envelope?
    end
  end
end
