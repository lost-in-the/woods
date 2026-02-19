# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # RakeTaskExtractor handles extraction of custom rake tasks from lib/tasks/.
    #
    # Scans `lib/tasks/**/*.rake` for task definitions and produces one
    # ExtractedUnit per task. Uses static regex parsing (never evals rake files).
    # Supports namespaced tasks, nested namespaces, task dependencies, and arguments.
    #
    # @example
    #   extractor = RakeTaskExtractor.new
    #   units = extractor.extract_all
    #   cleanup = units.find { |u| u.identifier == "cleanup:stale_orders" }
    #   cleanup.metadata[:description] # => "Remove orders older than 30 days"
    #
    class RakeTaskExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      RAKE_DIRECTORIES = %w[lib/tasks].freeze

      # Namespaces to exclude from extraction (this gem's own tasks)
      EXCLUDED_NAMESPACES = %w[codebase_index].freeze

      def initialize
        @directories = RAKE_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
      end

      # Extract all rake tasks from all discovered directories.
      #
      # @return [Array<ExtractedUnit>] List of rake task units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rake')].flat_map { |file| extract_rake_file(file) }
        end
      end

      # Extract rake tasks from a single .rake file.
      #
      # Returns an Array because each file may contain multiple task definitions.
      #
      # @param file_path [String] Path to the .rake file
      # @return [Array<ExtractedUnit>] List of rake task units
      def extract_rake_file(file_path)
        return [] unless file_path.to_s.end_with?('.rake')

        source = File.read(file_path)
        tasks = parse_tasks(source)

        tasks.filter_map do |task_data|
          next if excluded_namespace?(task_data[:full_name])

          build_unit(task_data, file_path, source)
        end
      rescue StandardError => e
        Rails.logger.error("Failed to extract rake tasks from #{file_path}: #{e.message}")
        []
      end

      private

      # Parse task definitions from rake source using a line-by-line state machine.
      #
      # Tracks namespace nesting, desc buffers, and task blocks.
      #
      # @param source [String] Rake file source code
      # @return [Array<Hash>] Parsed task data
      def parse_tasks(source)
        tasks = []
        namespace_stack = []
        # Track the block depth at which each namespace was opened.
        # When depth returns to that level, the namespace ends.
        namespace_depths = []
        pending_desc = nil
        depth = 0
        lines = source.lines

        lines.each_with_index do |line, index|
          stripped = line.strip

          # Track namespace blocks
          if stripped.match?(/\Anamespace\s+/)
            name = extract_namespace_name(stripped)
            if name
              namespace_stack.push(name)
              namespace_depths.push(depth)
              depth += 1
            end
            next
          end

          # Buffer desc for the next task
          if stripped.match?(/\Adesc\s+/)
            pending_desc = extract_desc(stripped)
            next
          end

          # Detect task definitions
          if stripped.match?(/\Atask\s+/)
            task_data = parse_task_line(stripped, namespace_stack, pending_desc, index + 1)
            if task_data
              task_data[:block_source] = extract_task_block(lines, index)
              tasks << task_data
            end
            pending_desc = nil
            depth += 1 if stripped.include?(' do')
            next
          end

          # Track block openers (non-namespace, non-task)
          depth += 1 if block_opener?(stripped)

          # Track end keywords
          next unless stripped == 'end'

          depth -= 1
          # Pop namespace if we've returned to the depth where it was opened
          if namespace_depths.any? && depth == namespace_depths.last
            namespace_stack.pop
            namespace_depths.pop
          end
        end

        tasks
      end

      # Extract the namespace name from a namespace declaration line.
      #
      # @param line [String] e.g. "namespace :foo do"
      # @return [String, nil] The namespace name
      def extract_namespace_name(line)
        match = line.match(/\Anamespace\s+:(\w+)/)
        match ? match[1] : nil
      end

      # Extract the description string from a desc line.
      #
      # @param line [String] e.g. "desc 'Remove stale orders'"
      # @return [String, nil] The description text
      def extract_desc(line)
        match = line.match(/\Adesc\s+(['"])(.*?)\1/)
        match ? match[2] : nil
      end

      # Parse a task definition line into structured data.
      #
      # @param line [String] The task line
      # @param namespace_stack [Array<String>] Current namespace nesting
      # @param description [String, nil] Buffered desc
      # @param line_number [Integer] 1-based line number
      # @return [Hash, nil] Parsed task data or nil if unparseable
      def parse_task_line(line, namespace_stack, description, line_number)
        task_name, deps, args = parse_task_signature(line)
        return nil unless task_name

        ns = namespace_stack.any? ? namespace_stack.join(':') : nil
        full_name = ns ? "#{ns}:#{task_name}" : task_name

        {
          task_name: task_name,
          full_name: full_name,
          task_namespace: ns,
          description: description,
          task_dependencies: deps,
          arguments: args,
          line_number: line_number
        }
      end

      # Parse the task name, dependencies, and arguments from a task signature.
      #
      # Handles:
      #   task :name
      #   task :name => :dep
      #   task :name => [:dep1, :dep2]
      #   task :name, [:arg1, :arg2] => :dep
      #
      # @param line [String] The task line
      # @return [Array(String, Array<String>, Array<String>)] [name, deps, args]
      def parse_task_signature(line)
        # Task with args: task :name, [:arg1, :arg2]
        if line.match(/\Atask\s+:(\w+)\s*,\s*\[([^\]]*)\]/)
          name = ::Regexp.last_match(1)
          args = ::Regexp.last_match(2).scan(/:(\w+)/).flatten

          # Check for dependencies after args
          deps = if line.match(/=>\s*(.+?)(?:\s+do|\s*$)/)
                   parse_dependency_list(::Regexp.last_match(1))
                 else
                   []
                 end

          return [name, deps, args]
        end

        # Task with hash-rocket deps: task :name => [:dep1, :dep2]
        if line.match(/\Atask\s+:(\w+)\s*=>\s*(.+?)(?:\s+do|\s*$)/)
          name = ::Regexp.last_match(1)
          deps = parse_dependency_list(::Regexp.last_match(2))
          return [name, deps, []]
        end

        # Simple task: task :name
        return [::Regexp.last_match(1), [], []] if line.match(/\Atask\s+:(\w+)/)

        nil
      end

      # Parse a dependency list from a hash-rocket right-hand side.
      #
      # @param dep_str [String] e.g. ":environment" or "[:dep1, :dep2]"
      # @return [Array<String>]
      def parse_dependency_list(dep_str)
        dep_str.scan(/:(\w+)/).flatten
      end

      # Extract the task block body (lines between task...do and matching end).
      #
      # @param lines [Array<String>] All source lines
      # @param task_line_index [Integer] 0-based index of the task line
      # @return [String] The block body source
      def extract_task_block(lines, task_line_index)
        task_line = lines[task_line_index]
        return '' unless task_line&.include?('do')

        depth = 1
        body_lines = []

        ((task_line_index + 1)...lines.size).each do |i|
          line = lines[i]
          stripped = line.strip

          depth += 1 if block_opener?(stripped)
          depth -= 1 if stripped == 'end'

          break if depth.zero?

          body_lines << line
        end

        body_lines.join
      end

      # Check if a line opens a new block (do...end or def...end).
      # Note: if/unless only count as block openers when they start the line
      # (standalone form), not as trailing modifiers (e.g., `return if x`).
      #
      # @param stripped [String] Stripped line content
      # @return [Boolean]
      def block_opener?(stripped)
        return true if stripped.match?(/\b(do|def|case|begin|class|module|while|until|for)\b.*(?<!\bend)\s*$/)

        stripped.match?(/\A(if|unless)\b/)
      end

      # Check if a task name falls under an excluded namespace.
      #
      # @param full_name [String] e.g. "codebase_index:extract"
      # @return [Boolean]
      def excluded_namespace?(full_name)
        EXCLUDED_NAMESPACES.any? { |ns| full_name.start_with?("#{ns}:") }
      end

      # Build an ExtractedUnit from parsed task data.
      #
      # @param task_data [Hash] Parsed task data
      # @param file_path [String] Path to the .rake file
      # @param file_source [String] Full file source
      # @return [ExtractedUnit]
      def build_unit(task_data, file_path, file_source)
        unit = ExtractedUnit.new(
          type: :rake_task,
          identifier: task_data[:full_name],
          file_path: file_path
        )

        unit.namespace = task_data[:task_namespace]
        unit.source_code = build_source_annotation(task_data, file_source)
        unit.metadata = build_metadata(task_data)
        unit.dependencies = extract_dependencies(task_data, file_source)

        unit
      end

      # Build annotated source code for the unit.
      #
      # @param task_data [Hash] Parsed task data
      # @param file_source [String] Full file source
      # @return [String]
      def build_source_annotation(task_data, file_source)
        header = "# Rake task: #{task_data[:full_name]}"
        header += "\n# #{task_data[:description]}" if task_data[:description]
        "#{header}\n#{file_source}"
      end

      # Build metadata hash for the unit.
      #
      # @param task_data [Hash] Parsed task data
      # @return [Hash]
      def build_metadata(task_data)
        {
          task_name: task_data[:task_name],
          full_name: task_data[:full_name],
          description: task_data[:description],
          task_namespace: task_data[:task_namespace],
          task_dependencies: task_data[:task_dependencies],
          arguments: task_data[:arguments],
          has_environment_dependency: task_data[:task_dependencies].include?('environment'),
          source_lines: (task_data[:block_source] || '').lines.size
        }
      end

      # Extract dependencies from task source.
      #
      # Combines common dependency scanning with cross-task invocation detection.
      #
      # @param task_data [Hash] Parsed task data
      # @param file_source [String] Full file source
      # @return [Array<Hash>]
      def extract_dependencies(task_data, file_source)
        deps = scan_common_dependencies(task_data[:block_source] || file_source)

        # Detect Rake::Task invocations
        (task_data[:block_source] || '').scan(/Rake::Task\[['"]([^'"]+)['"]\]\.invoke/) do |match|
          deps << { type: :rake_task, target: match[0], via: :task_invoke }
        end

        # Add task dependency references
        task_data[:task_dependencies].each do |dep|
          next if dep == 'environment'

          deps << { type: :rake_task, target: dep, via: :task_dependency }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
