# frozen_string_literal: true

require_relative 'ast'
require_relative 'extracted_unit'
require_relative 'ruby_analyzer/class_analyzer'
require_relative 'ruby_analyzer/method_analyzer'
require_relative 'ruby_analyzer/dataflow_analyzer'
require_relative 'ruby_analyzer/trace_enricher'

module CodebaseIndex
  # Analyzes plain Ruby source code and produces ExtractedUnit objects.
  #
  # Orchestrates ClassAnalyzer, MethodAnalyzer, DataFlowAnalyzer, and
  # optional TraceEnricher to extract structured data from Ruby files.
  #
  # @example Analyze gem source
  #   units = CodebaseIndex::RubyAnalyzer.analyze(paths: ["lib/"])
  #   units.select { |u| u.type == :ruby_class }.map(&:identifier)
  #
  module RubyAnalyzer
    class << self
      # Analyze Ruby source files and produce ExtractedUnit objects.
      #
      # @param paths [Array<String>] File paths or directories to analyze
      # @param trace_data [Array<Hash>, nil] Optional runtime trace data for enrichment
      # @return [Array<ExtractedUnit>] All extracted units
      def analyze(paths:, trace_data: nil)
        files = discover_files(paths)
        return [] if files.empty?

        parser = Ast::Parser.new
        class_analyzer = ClassAnalyzer.new(parser: parser)
        method_analyzer = MethodAnalyzer.new(parser: parser)
        dataflow_analyzer = DataFlowAnalyzer.new(parser: parser)

        units = []

        files.each do |file_path|
          source = read_file(file_path)
          next unless source

          units.concat(class_analyzer.analyze(source: source, file_path: file_path))
          units.concat(method_analyzer.analyze(source: source, file_path: file_path))
        rescue CodebaseIndex::ExtractionError
          # Skip files that fail to parse
          next
        end

        dataflow_analyzer.annotate(units)
        TraceEnricher.merge(units: units, trace_data: trace_data) if trace_data

        units
      end

      private

      # Discover .rb files from a list of paths (files and/or directories).
      #
      # @param paths [Array<String>] File paths or directory paths
      # @return [Array<String>] Absolute paths to .rb files
      def discover_files(paths)
        files = []
        paths.each do |path|
          expanded = File.expand_path(path)
          if File.directory?(expanded)
            Dir.glob(File.join(expanded, '**', '*.rb')).sort.each do |f|
              files << f
            end
          elsif File.file?(expanded) && expanded.end_with?('.rb')
            files << expanded
          end
        end
        files.uniq
      end

      # Read a file safely, returning nil on failure.
      #
      # @param path [String] File path
      # @return [String, nil] File contents or nil
      def read_file(path)
        File.read(path)
      rescue StandardError
        nil
      end
    end
  end
end
