# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../ast/call_site_extractor'

module CodebaseIndex
  module RubyAnalyzer
    # Annotates existing ExtractedUnit objects with data transformation metadata.
    #
    # Conservative v1: detects common data transformation patterns by scanning
    # for specific method calls that indicate construction, serialization, or
    # deserialization.
    #
    # @example
    #   analyzer = RubyAnalyzer::DataFlowAnalyzer.new
    #   analyzer.annotate(units)
    #   units.first.metadata[:data_transformations]
    #   #=> [{ method: "to_json", category: :serialization, line: 5 }]
    #
    class DataFlowAnalyzer
      CONSTRUCTION_METHODS = %w[new].freeze
      SERIALIZATION_METHODS = %w[to_h to_json to_a serialize as_json].freeze
      DESERIALIZATION_METHODS = %w[from_json parse].freeze
      CATEGORY_BY_METHOD = [
        *CONSTRUCTION_METHODS.map { |m| [m, :construction] },
        *SERIALIZATION_METHODS.map { |m| [m, :serialization] },
        *DESERIALIZATION_METHODS.map { |m| [m, :deserialization] }
      ].to_h.freeze

      # @param parser [Ast::Parser, nil] Parser instance (creates default if nil)
      def initialize(parser: nil)
        @parser = parser || Ast::Parser.new
        @call_site_extractor = Ast::CallSiteExtractor.new
      end

      # Annotate units with data transformation metadata.
      #
      # Mutates each unit's metadata hash by adding a :data_transformations key.
      #
      # @param units [Array<ExtractedUnit>] Units to annotate
      # @return [Array<ExtractedUnit>] The same units, now annotated
      def annotate(units)
        units.each do |unit|
          next unless unit.source_code

          transformations = detect_transformations(unit.source_code)
          unit.metadata[:data_transformations] = transformations
        end
      end

      private

      def detect_transformations(source)
        root = @parser.parse(source)
        calls = @call_site_extractor.extract(root)

        calls.filter_map do |call|
          category = categorize(call[:method_name])
          next unless category

          {
            method: call[:method_name],
            category: category,
            receiver: call[:receiver],
            line: call[:line]
          }
        end
      rescue CodebaseIndex::ExtractionError
        []
      end

      def categorize(method_name)
        CATEGORY_BY_METHOD[method_name]
      end
    end
  end
end
