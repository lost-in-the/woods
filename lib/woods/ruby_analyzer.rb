# frozen_string_literal: true

require_relative 'ast'
require_relative 'extracted_unit'
require_relative 'ruby_analyzer/class_analyzer'
require_relative 'ruby_analyzer/method_analyzer'
require_relative 'ruby_analyzer/dataflow_analyzer'
require_relative 'ruby_analyzer/trace_enricher'

module Woods
  # Analyzes plain Ruby source code and produces ExtractedUnit objects.
  #
  # Orchestrates ClassAnalyzer, MethodAnalyzer, DataFlowAnalyzer, and
  # optional TraceEnricher to extract structured data from Ruby files.
  #
  # @example Analyze gem source
  #   units = Woods::RubyAnalyzer.analyze(paths: ["lib/"])
  #   units.select { |u| u.type == :ruby_class }.map(&:identifier)
  #
  module RubyAnalyzer
    class << self
      # Analyze Ruby source files and produce ExtractedUnit objects.
      #
      # @param paths [Array<String>, nil] File paths or directories to analyze
      # @param sources [Hash{String => String}, nil] Pre-read source keyed by
      #   absolute file path. This lets callers analyze one consistent source
      #   snapshot rather than re-reading files while they may be changing.
      # @param trace_data [Array<Hash>, nil] Optional runtime trace data for enrichment
      # @return [Array<ExtractedUnit>] All extracted units
      def analyze(paths: nil, sources: nil, trace_data: nil)
        files = sources ? sources.keys.sort : discover_files(Array(paths))
        return [] if files.empty?

        parser = Ast::Parser.new
        class_analyzer = ClassAnalyzer.new(parser: parser)
        method_analyzer = MethodAnalyzer.new(parser: parser)
        dataflow_analyzer = DataFlowAnalyzer.new(parser: parser)

        units = []

        files.each do |file_path|
          source = source_for(file_path, sources)
          next unless source

          units.concat(class_analyzer.analyze(source: source, file_path: file_path))
          units.concat(method_analyzer.analyze(source: source, file_path: file_path))
        rescue Woods::ExtractionError
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
            Dir.glob(File.join(expanded, '**', '*.rb')).each do |f|
              files << f
            end
          elsif File.file?(expanded) && expanded.end_with?('.rb')
            files << expanded
          end
        end
        files.uniq
      end

      def source_for(file_path, sources)
        return sources.fetch(file_path) if sources

        read_file(file_path)
      end

      # Read a file safely, returning nil on failure.
      #
      # Ruby source defaults to UTF-8, so the read is pinned to UTF-8
      # rather than the process default external encoding. Under LANG=C
      # (US-ASCII) a bare File.read tags multibyte source, such as an em
      # dash in a comment, as invalid and JSON generation raises
      # Encoding::InvalidByteSequenceError out of the analysis.
      #
      # @param path [String] File path
      # @return [String, nil] File contents or nil
      def read_file(path)
        content = File.read(path, encoding: Encoding::UTF_8)
        content.valid_encoding? ? content : content.scrub
      rescue StandardError
        nil
      end
    end
  end
end
