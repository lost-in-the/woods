# frozen_string_literal: true

require 'set'

module Woods
  module Extractors
    # Every rake task the parsed files define or enhance, merged by task name.
    #
    # Rake merges a task that is reopened or enhanced anywhere into one task,
    # so the catalog does the same: {#records_for} returns each definition and
    # enhancement of a name, across files, in file and line order.
    #
    # The source is the authority wherever it is written out. The loaded Rake
    # application ({RakeRuntimeIndex}) is consulted only for what the source
    # computes: a task name, a namespace, a prerequisite list or a description
    # that is not a literal. A resident process keeps a stale application after
    # an edit and a process that never loaded Rake has none, so nothing a file
    # states literally may depend on it.
    #
    # @example
    #   parsed = { '/app/lib/tasks/db.rake' => RakeSourceParser.parse("task seed: :environment\n") }
    #   catalog = RakeTaskCatalog.new(task_files: parsed, support_files: {}, runtime: RakeRuntimeIndex.new(nil))
    #   catalog.names # => ["seed"]
    class RakeTaskCatalog
      # Methods that hand a command to the operating system.
      SHELL_METHODS = %w[sh system exec spawn].freeze

      # Receivers those methods are called on. +nil+ is a bare call.
      SHELL_RECEIVERS = [nil, 'Kernel', 'Process'].freeze

      # Modules whose every call runs a command.
      SHELL_MODULES = %w[Open3].freeze

      COMMAND_LIMIT = 200

      # @param task_files [Hash{String => RakeSourceParser::Result}] absolute path => parse
      # @param support_files [Hash{String => RakeSourceParser::Result}] root-relative path => parse
      # @param runtime [RakeRuntimeIndex]
      def initialize(task_files:, support_files:, runtime:)
        @task_files = task_files.sort.to_h
        @support_files = support_files.sort.to_h
        @runtime = runtime
      end

      # @return [Array<String>] every task name, in file order then source order
      def names
        records.keys
      end

      # @param file [String] absolute path
      # @return [Array<String>] the names with a definition or enhancement in +file+
      def names_in(file)
        records.select { |_, entries| entries.any? { |entry| entry[:file] == file } }.keys
      end

      # @param name [String] full task name
      # @return [Array<Hash>] its definitions and enhancements, sorted by file then line
      def records_for(name)
        records.fetch(name, [])
      end

      # The task a name refers to from inside a namespace, by Rake's own rule:
      # innermost scope first, then each enclosing scope, then the top level.
      #
      # @param raw [String] a prerequisite or lookup name as written
      # @param namespace [Array<String, nil>] enclosing namespace segments
      # @return [String] the full name of a known task, else +raw+
      def resolve(raw, namespace)
        name = raw.to_s
        return name.delete_prefix('rake:') if name.start_with?('rake:')

        scope = namespace.include?(nil) ? [] : namespace
        while name.start_with?('^')
          name = name.delete_prefix('^')
          scope = scope[0...-1]
        end
        scope.size.downto(0) do |depth|
          candidate = (scope.first(depth) + [name]).join(':')
          return candidate if known_names.include?(candidate)
        end
        name
      end

      # @param facts [Hash] {RakeBodyFacts.collect} output
      # @return [Array<String>] literal commands the body runs, each cut to {COMMAND_LIMIT} characters
      def shell_commands(facts)
        called = facts[:calls].select { |call| call[:command] && shell_call?(call) }.map { |call| call[:command] }
        (called + facts[:commands]).map { |command| command[0, COMMAND_LIMIT] }.uniq
      end

      # Edges from a body to the support files whose methods it calls or whose
      # constants it names.
      #
      # @param facts [Hash] {RakeBodyFacts.collect} output
      # @param except [String, nil] a support file to leave out (the caller itself)
      # @return [Array<Hash>] dependency hashes targeting support file identifiers
      def support_dependencies(facts, except: nil)
        called = facts[:calls].flat_map { |call| support_methods.fetch(call[:name], []) }
        named = facts[:constants].flat_map { |constant| declaring_files(constant) }
        edges = called.map { |file| [file, :method_call] } + named.map { |file| [file, :code_reference] }
        edges.reject { |file, _| file == except }.uniq(&:first)
             .map { |file, via| { type: :rake_task, target: file, via: via } }
      end

      private

      def records
        @records ||= begin
          grouped = Hash.new { |hash, name| hash[name] = [] }
          (definition_records + enhancement_records).each { |record| grouped[record[:name]] << record }
          grouped.transform_values { |entries| entries.sort_by { |entry| [entry[:file], entry[:line]] } }
        end
      end

      def known_names
        @known_names ||= Set.new(definition_records.map { |record| record[:name] })
      end

      def definition_records
        @definition_records ||= @task_files.flat_map do |file, parsed|
          parsed.definitions.flat_map { |definition| records_from(definition, file) }
        end
      end

      def enhancement_records
        @task_files.flat_map do |file, parsed|
          parsed.enhancements.map do |enhancement|
            enhancement.merge(
              name: resolve(enhancement[:target], enhancement[:namespace]), file: file, kind: :enhancement,
              enhancement: true, description: nil, arguments: [], task_class: nil
            )
          end
        end
      end

      # One record per task the definition creates: one when the source names
      # it, as many as the runtime reports when the name is computed.
      def records_from(definition, file)
        loaded = @runtime.tasks_at(file, definition[:line], definition[:block_line] || definition[:line])
        if definition[:full_name]
          task = loaded.find { |candidate| candidate[:name] == definition[:full_name] }
          return [record_for(definition, file, definition[:full_name], task, computed: false)]
        end

        matching(loaded, definition[:name]).map do |task|
          record_for(definition, file, task[:name], task, computed: true)
        end
      end

      def matching(loaded, short_name)
        return loaded unless short_name

        loaded.select { |task| task[:name] == short_name || task[:name].end_with?(":#{short_name}") }
      end

      def record_for(definition, file, name, task, computed:)
        definition.merge(
          name: name, file: file, enhancement: false, name_source: computed ? 'runtime' : nil,
          namespace: computed ? name.split(':')[0...-1] : definition[:namespace],
          description: definition[:description] || (task[:description] if task && !definition[:description_literal]),
          prerequisites: task && !definition[:prerequisites_literal] ? task[:prerequisites] : definition[:prerequisites],
          arguments: computed && definition[:arguments].empty? ? task[:arguments] : definition[:arguments]
        )
      end

      def shell_call?(call)
        shell_builtin?(call) || shell_wrappers.include?(call[:name])
      end

      def shell_builtin?(call)
        SHELL_MODULES.include?(call[:receiver]) ||
          (SHELL_METHODS.include?(call[:name]) && SHELL_RECEIVERS.include?(call[:receiver]))
      end

      # Methods defined in the rake files or their support files that shell
      # out, directly or through another such method. One pass from the
      # direct ones outward through their callers.
      def shell_wrappers
        @shell_wrappers ||= begin
          definitions = (@task_files.values + @support_files.values).flat_map(&:method_definitions)
          queue = definitions.select { |definition| shells_out?(definition[:facts]) }.map { |d| d[:name] }.uniq
          wrappers = Set.new(queue)
          callers = callers_by_callee(definitions)
          callers.fetch(queue.shift, []).each { |name| queue << name if wrappers.add?(name) } until queue.empty?
          wrappers
        end
      end

      def shells_out?(facts)
        facts[:commands].any? || facts[:calls].any? { |call| shell_builtin?(call) }
      end

      def callers_by_callee(definitions)
        definitions.each_with_object(Hash.new { |hash, name| hash[name] = [] }) do |definition, callers|
          definition[:facts][:calls].each { |call| callers[call[:name]] << definition[:name] }
        end
      end

      def support_methods
        @support_methods ||= support_index { |parsed| parsed.method_definitions.map { |definition| definition[:name] } }
      end

      def support_constants
        @support_constants ||= support_index(&:constants)
      end

      # `Palette::DEFAULT` names whatever declares `Palette::DEFAULT` or `Palette`.
      def declaring_files(constant)
        segments = constant.split('::')
        segments.size.downto(1).flat_map { |length| support_constants.fetch(segments.first(length).join('::'), []) }
      end

      # @return [Hash{String => Array<String>}] name => the sorted support files declaring it
      def support_index
        @support_files.each_with_object(Hash.new { |hash, name| hash[name] = [] }) do |(file, parsed), index|
          yield(parsed).uniq.each { |name| index[name] << file }
        end
      end
    end
  end
end
