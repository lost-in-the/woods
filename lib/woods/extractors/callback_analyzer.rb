# frozen_string_literal: true

require 'set'
require_relative '../ast/parser'
require_relative '../flow_analysis/operation_extractor'
require_relative 'line_neutralizer'
require_relative 'reference_patterns'
require_relative 'source_nesting'

module Woods
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
      ASYNC_METHODS = ReferencePatterns::ENQUEUE_METHODS

      # Assignment to a column through +self+: plain, conditional (`||=`,
      # `&&=`), or arithmetic (`+=`, `-=`, `*=`, `/=`). `self.token ||=
      # SecureRandom.uuid` in a before_create is arguably the most common
      # callback body in Rails and reported no write at all (EXTA-6). The
      # lookahead rejects `==` (comparison) and `=~` (regex match), the
      # latter having been read as a write. The word and the space after it
      # are possessive: neither can end anywhere but where it does.
      SELF_ASSIGNMENT_PATTERN = %r{self\.(\w++)\s*+(?:\|\||&&|[+\-*/])?=(?!=|~)}

      # Pre-compiled regex patterns (avoid dynamic regex construction in hot
      # loops). One whitespace run per side of the optional paren:
      # `\s*\(?\s*` let both runs split the same spaces, quadratic without
      # the Ruby 3.2+ match cache.
      SINGLE_COLUMN_WRITER_PATTERNS = SINGLE_COLUMN_WRITERS.to_h do |w|
        [w, /\b#{Regexp.escape(w)}\s*+(?:\(\s*+)?[:'"](\w+)/]
      end.freeze

      MULTI_COLUMN_WRITER_PATTERNS = MULTI_COLUMN_WRITERS.to_h do |w|
        [w, /\b#{Regexp.escape(w)}\s*+\(([^)]++)\)/m]
      end.freeze

      # A `name:` key inside a multi-column writer's argument list.
      KEYWORD_PATTERN = /\b(\w++)\s*+:(?!:)/

      DB_READ_PATTERNS = DB_READ_METHODS.to_h do |m|
        [m, /\.#{Regexp.escape(m)}\b/]
      end.freeze

      # @param source_code [String] Composite model source (with inlined concerns)
      # @param column_names [Array<String>] Model's database column names
      # @param segments [Array<Hash>, nil] where each part of +source_code+
      #   came from, as `{ start:, length:, file: }` with 1-based lines and a
      #   file relative to the application root (nil outside it). With
      #   segments, operation lines are reported in their own file; without,
      #   they stay lines of +source_code+.
      # @return [Ast::Node, nil] the parsed source, nil when it does not parse
      attr_reader :parsed_root

      def initialize(source_code:, column_names: [], segments: nil)
        @source_code = source_code
        @segments = segments
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

        method_source = scannable_source(method_source_from_node(method_node))
        return callback_hash.merge(side_effects: empty_side_effects) if method_source.nil?

        callback_hash.merge(
          side_effects: {
            columns_written: detect_columns_written(method_source),
            jobs_enqueued: detect_jobs_enqueued(method_source, nesting_for(method_node)),
            services_called: detect_services_called(method_source),
            mailers_triggered: detect_mailers_triggered(method_source),
            database_reads: detect_database_reads(method_source),
            operations: extract_operations(method_node)
          }
        )
      end

      # Side effects of one method definition, for a caller that already
      # holds its node (two methods can share a name, so a filter cannot
      # tell them apart).
      #
      # Unlike {#analyze}, service and mailer names are resolved in the
      # method's lexical scope, as job names are, so each entry agrees with
      # the unit's own edge to that class.
      #
      # @param method_node [Ast::Node] a :def or :defs node of {#parsed_root}
      # @return [Hash, nil] `{ columns_written:, jobs_enqueued:,
      #   services_called:, mailers_triggered:, source: }` where +source+ is
      #   the neutralized method text the scans ran over; nil when the method
      #   has no readable source
      def method_effects(method_node)
        method_source = method_scan_source(method_node)
        return nil if method_source.nil?

        nesting = nesting_for(method_node)
        {
          columns_written: detect_columns_written(method_source),
          jobs_enqueued: detect_jobs_enqueued(method_source, nesting),
          services_called: detect_services_called(method_source, nesting),
          mailers_triggered: detect_mailers_triggered(method_source, nesting),
          source: method_source
        }
      end

      private

      # Parse source code safely, returning nil on failure. Source nested
      # deeper than the stack can follow (a constant path thousands of
      # segments long) counts as a failure, not a crash.
      #
      # @return [Ast::Node, nil]
      def safe_parse
        @parser.parse(@source_code)
      rescue StandardError, SystemStackError
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
        if node.start_byte && node.end_byte
          return @source_code.byteslice(node.start_byte, node.end_byte - node.start_byte)
        end

        return node.source if node.source

        return nil unless node.line && node.end_line

        lines = @source_code.lines
        start_idx = node.line - 1
        end_idx = node.end_line - 1
        return nil if start_idx.negative? || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end

      # A nested definition installs a method; its body does not run with
      # the enclosing method. Blank only those byte ranges, preserving
      # newlines and all surrounding executable source.
      def method_scan_source(node)
        source = method_source_from_node(node)
        return nil unless source

        if node.start_byte
          ranges = []
          pending = Array(node.children).dup
          while (child = pending.pop)
            next unless child.is_a?(Ast::Node)

            if %i[def defs].include?(child.type)
              first = child.start_byte && (child.start_byte - node.start_byte)
              last = child.end_byte && (child.end_byte - node.start_byte)
              next unless first && last && first >= 0 && last <= source.bytesize

              ranges << [first, last]
            else
              pending.concat(Array(child.children))
            end
          end
          cursor = 0
          pieces = ranges.sort.flat_map do |first, last|
            prefix = source.byteslice(cursor, first - cursor)
            blank = source.byteslice(first, last - first).b.gsub(/[^\n]/, ' ').force_encoding(source.encoding)
            cursor = last
            [prefix, blank]
          end
          source = (pieces << source.byteslice(cursor..-1)).join
        end
        scannable_source(source)
      end

      # Neutralize a method body before the regex scans run over it.
      #
      # The body is located by AST but scanned by regex, so
      # `logger.info "self.status = pending"` and a commented-out
      # `# self.status = 'x'` both reported a column write (EXTA-8).
      # {LineNeutralizer} blanks comment and string-literal bodies, which is
      # exactly the text a side-effect scan must not believe; identifiers,
      # call chains, and symbols — everything the patterns actually match —
      # survive untouched.
      #
      # @param method_source [String, nil]
      # @return [String, nil]
      def scannable_source(method_source)
        return nil if method_source.nil?

        LineNeutralizer.neutralize_lines(method_source).join
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

        # Pattern: self.col = value (plain, ||=, &&=, +=, … — never == or =~)
        method_source.scan(SELF_ASSIGNMENT_PATTERN).flatten.each do |col|
          columns << col if @column_names.include?(col)
        end

        # Pattern: update_column(:col, ...) / write_attribute(:col, ...)
        SINGLE_COLUMN_WRITER_PATTERNS.each_value do |pattern|
          method_source.scan(pattern).flatten.each do |col|
            columns << col if @column_names.include?(col)
          end
        end

        # Pattern: update_columns(col: ...) / assign_attributes(col: ...)
        closable = closable_source(method_source)
        MULTI_COLUMN_WRITER_PATTERNS.each_value do |pattern|
          closable.scan(pattern).each do |match|
            match[0].scan(KEYWORD_PATTERN).flatten.each do |col|
              columns << col if @column_names.include?(col)
            end
          end
        end

        columns.to_a.sort
      end

      # The source up to its last closing paren. An argument list can only
      # close there or earlier, and past it every unclosed `update_columns(`
      # would be read to the end of the method before failing: quadratic in
      # a body that repeats one.
      #
      # @param method_source [String]
      # @return [String]
      def closable_source(method_source)
        last = method_source.rindex(')')
        last ? method_source[0..last] : ''
      end

      # Detect jobs enqueued by the callback method.
      #
      # Matches Job/Worker classes calling async dispatch methods, named the
      # way Ruby resolves them inside the class that defines the method, so
      # an entry agrees with the model's enqueue edge.
      #
      # @param method_source [String]
      # @param nesting [Array<String>] scopes around the method, innermost first
      # @return [Array<String>]
      def detect_jobs_enqueued(method_source, nesting = [])
        ReferencePatterns.job_enqueues(method_source, enclosing: nesting).uniq.sort
      end

      # The class and module scopes open at the method's byte offset in
      # the composite source, innermost first. A line can also contain the
      # class declaration, so its start is only a fallback.
      #
      # @param node [Ast::Node] the method definition
      # @return [Array<String>]
      def nesting_for(node)
        offset = node.start_byte || (node.line && line_starts[node.line - 1])
        return [] unless offset

        @lexical_scopes ||= SourceNesting.lexical_scopes(@source_code) || []
        @lexical_scopes.select { |start, finish, _| start <= offset && offset < finish }.reverse.map(&:last)
      end

      # Byte offset at which each line of the composite source starts.
      #
      # @return [Array<Integer>]
      def line_starts
        @line_starts ||= @source_code.each_line.with_object([0]) do |text, starts|
          starts << (starts.last + text.bytesize)
        end
      end

      # Detect service objects called by the callback method.
      #
      # Matches classes ending in Service followed by a method call,
      # namespace included (EXTA-2).
      #
      # @param method_source [String]
      # @param nesting [Array<String>] scopes around the method, innermost first
      # @return [Array<String>]
      def detect_services_called(method_source, nesting = [])
        ReferencePatterns.references(method_source, **ReferencePatterns::SERVICE_RULE, enclosing: nesting).uniq.sort
      end

      # Detect mailers triggered by the callback method.
      #
      # Matches classes ending in Mailer followed by a method call,
      # namespace included (EXTA-2).
      #
      # @param method_source [String]
      # @param nesting [Array<String>] scopes around the method, innermost first
      # @return [Array<String>]
      def detect_mailers_triggered(method_source, nesting = [])
        ReferencePatterns.references(method_source, **ReferencePatterns::MAILER_RULE, enclosing: nesting).uniq.sort
      end

      # Detect database read operations in the callback method.
      #
      # Checks for common ActiveRecord query methods called via dot notation.
      #
      # @param method_source [String]
      # @return [Array<String>]
      def detect_database_reads(method_source)
        DB_READ_PATTERNS.filter_map do |method, pattern|
          method if method_source.match?(pattern)
        end
      end

      # Extract operations using OperationExtractor from the method's AST node.
      #
      # @param method_node [Ast::Node, nil]
      # @return [Array<Hash>]
      def extract_operations(method_node)
        return [] unless method_node

        operations = @operation_extractor.extract(method_node)
        return operations unless @segments

        FlowAnalysis::OperationExtractor.relocate(operations) { |line| segment_location(line) }
      rescue StandardError
        []
      end

      # @param line [Integer, nil] a line of the analysis source
      # @return [Array(Integer, String)] the line in, and the path of, the
      #   file that line came from; nils when that file is outside the
      #   application root or the line belongs to no segment
      def segment_location(line)
        segment = line && @segments.find { |part| line >= part[:start] && line < part[:start] + part[:length] }
        return [nil, nil] unless segment && segment[:file]

        [line - segment[:start] + 1, segment[:file]]
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
