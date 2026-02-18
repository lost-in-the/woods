# frozen_string_literal: true

require 'set'
require_relative '../ast/parser'
require_relative '../flow_analysis/operation_extractor'

module CodebaseIndex
  module Extractors
    # Analyzes callback method bodies to detect side effects.
    #
    # Given a model's composite source code (with inlined concerns) and its
    # callback metadata, this analyzer finds each callback method body and
    # classifies its side effects: column writes, job enqueues, service calls,
    # mailer triggers, and database reads.
    #
    # @example
    #   analyzer = CallbackAnalyzer.new(
    #     source_code: model_source,
    #     column_names: %w[email status name]
    #   )
    #   enriched = analyzer.analyze(callback_hash)
    #   enriched[:side_effects][:columns_written] #=> ["email"]
    #
    class CallbackAnalyzer
      # Database query methods that indicate a read operation.
      DB_READ_METHODS = %w[find where pluck first last].freeze

      # Methods that write a single column, taking column name as first argument.
      SINGLE_COLUMN_WRITERS = %w[update_column write_attribute].freeze

      # Methods that write multiple columns via keyword arguments.
      MULTI_COLUMN_WRITERS = %w[update_columns assign_attributes].freeze

      # Async enqueue methods that indicate a job is being dispatched.
      ASYNC_METHODS = %w[perform_later perform_async perform_in perform_at].freeze

      # @param source_code [String] Composite model source (with inlined concerns)
      # @param column_names [Array<String>] Model's database column names
      def initialize(source_code:, column_names: [])
        @source_code = source_code
        @column_names = column_names.map(&:to_s)
        @parser = Ast::Parser.new
        @operation_extractor = FlowAnalysis::OperationExtractor.new
        @parsed_root = safe_parse
      end

      # Analyze a single callback and enrich it with side-effect data.
      #
      # Finds the callback's method body in the source, scans it for
      # side effects, and returns the original callback hash with an
      # added :side_effects key.
      #
      # @param callback_hash [Hash] Callback metadata from ModelExtractor:
      #   { type:, filter:, kind:, conditions: }
      # @return [Hash] The callback hash with an added :side_effects key
      def analyze(callback_hash)
        filter = callback_hash[:filter].to_s
        method_node = find_method_node(filter)

        return callback_hash.merge(side_effects: empty_side_effects) if method_node.nil?

        method_source = method_source_from_node(method_node)
        return callback_hash.merge(side_effects: empty_side_effects) if method_source.nil?

        callback_hash.merge(
          side_effects: {
            columns_written: detect_columns_written(method_source),
            jobs_enqueued: detect_jobs_enqueued(method_source),
            services_called: detect_services_called(method_source),
            mailers_triggered: detect_mailers_triggered(method_source),
            database_reads: detect_database_reads(method_source),
            operations: extract_operations(method_node)
          }
        )
      end

      private

      # Parse source code safely, returning nil on failure.
      #
      # @return [Ast::Node, nil]
      def safe_parse
        @parser.parse(@source_code)
      rescue StandardError
        nil
      end

      # Find a method definition node by name in the cached AST.
      #
      # @param method_name [String]
      # @return [Ast::Node, nil]
      def find_method_node(method_name)
        return nil unless @parsed_root
        return nil if method_name.empty? || !valid_method_name?(method_name)

        @parsed_root.find_all(:def).find do |node|
          node.method_name == method_name
        end
      end

      # Extract the raw source text of a method from its AST node.
      #
      # @param node [Ast::Node]
      # @return [String, nil]
      def method_source_from_node(node)
        return node.source if node.source

        return nil unless node.line && node.end_line

        lines = @source_code.lines
        start_idx = node.line - 1
        end_idx = node.end_line - 1
        return nil if start_idx.negative? || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end

      # Check if a filter string looks like a valid Ruby method name.
      # Rejects proc/lambda string representations and other non-method filters.
      #
      # @param name [String]
      # @return [Boolean]
      def valid_method_name?(name)
        name.match?(/\A[a-z_]\w*[!?=]?\z/i)
      end

      # Detect columns written by the callback method.
      #
      # Scans for self.col= assignments, update_column, update_columns,
      # write_attribute, and assign_attributes calls, cross-referencing
      # against the model's known column_names.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_columns_written(method_source)
        columns = Set.new

        # Pattern: self.col = value (direct assignment, not ==)
        method_source.scan(/self\.(\w+)\s*=(?!=)/).flatten.each do |col|
          columns << col if @column_names.include?(col)
        end

        # Pattern: update_column(:col, ...) / write_attribute(:col, ...)
        SINGLE_COLUMN_WRITERS.each do |writer|
          method_source.scan(/\b#{Regexp.escape(writer)}\s*\(?\s*[:'"](\w+)/).flatten.each do |col|
            columns << col if @column_names.include?(col)
          end
        end

        # Pattern: update_columns(col: ...) / assign_attributes(col: ...)
        MULTI_COLUMN_WRITERS.each do |writer|
          method_source.scan(/\b#{Regexp.escape(writer)}\s*\(([^)]+)\)/m).each do |match|
            match[0].scan(/\b(\w+)\s*:(?!:)/).flatten.each do |col|
              columns << col if @column_names.include?(col)
            end
          end
        end

        columns.to_a.sort
      end

      # Detect jobs enqueued by the callback method.
      #
      # Matches Job/Worker classes calling async dispatch methods.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_jobs_enqueued(method_source)
        async_pattern = ASYNC_METHODS.map { |m| Regexp.escape(m) }.join('|')
        method_source.scan(/(\w+(?:Job|Worker))\.(?:#{async_pattern})/).flatten.uniq.sort
      end

      # Detect service objects called by the callback method.
      #
      # Matches classes ending in Service followed by a method call.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_services_called(method_source)
        method_source.scan(/(\w+Service)(?:\.|::)/).flatten.uniq.sort
      end

      # Detect mailers triggered by the callback method.
      #
      # Matches classes ending in Mailer followed by a method call.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_mailers_triggered(method_source)
        method_source.scan(/(\w+Mailer)\./).flatten.uniq.sort
      end

      # Detect database read operations in the callback method.
      #
      # Checks for common ActiveRecord query methods called via dot notation.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_database_reads(method_source)
        DB_READ_METHODS.select do |method|
          method_source.match?(/\.#{Regexp.escape(method)}\b/)
        end
      end

      # Extract operations using OperationExtractor from the method's AST node.
      #
      # @param method_node [Ast::Node, nil]
      # @return [Array<Hash>]
      def extract_operations(method_node)
        return [] unless method_node

        @operation_extractor.extract(method_node)
      rescue StandardError
        []
      end

      # Return an empty side-effects structure.
      #
      # @return [Hash]
      def empty_side_effects
        {
          columns_written: [],
          jobs_enqueued: [],
          services_called: [],
          mailers_triggered: [],
          database_reads: [],
          operations: []
        }
      end
    end
  end
end
