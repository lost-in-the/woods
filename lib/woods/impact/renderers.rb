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
                data['coverage'].is_a?(Hash) && arrays?(data)
        raise ArgumentError, 'Unsupported impact schema or report shape' unless valid

        sparse_view(data)
      end
      private_class_method :document

      def self.arrays?(data)
        required = %w[changed affected flows risks tests unknowns]
        optional = %w[tables templates].select { |key| data.key?(key) }
        (required + optional).all? { |key| data[key].is_a?(Array) }
      end
      private_class_method :arrays?

      # Render-only view for previously accepted sparse schema 1 hashes.
      # Stored bytes and the caller's report values remain untouched.
      def self.sparse_view(data)
        missing = %w[tables templates].reject { |key| data.key?(key) }
        return data if missing.empty?

        coverage = data['coverage'].merge('complete' => false).merge(missing.to_h { |key| [key, 'not_computed'] })
        unknowns = missing.map { |key| { 'kind' => 'not_computed', 'feature' => key } }
        data.merge(missing.to_h { |key| [key, []] })
            .merge('coverage' => coverage, 'unknowns' => data['unknowns'] + unknowns)
      end
      private_class_method :sparse_view

      def self.envelope?(data)
        return data['range'].is_a?(Hash) unless data.dig('parameters', 'mode') == 'focus'

        data['range'].nil? && data['endpoint'].is_a?(Hash) && data['focus'].is_a?(Array) && data['changed'] == []
      end
      private_class_method :envelope?
    end
  end
end
