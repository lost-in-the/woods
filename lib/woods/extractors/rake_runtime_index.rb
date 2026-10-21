# frozen_string_literal: true

module Woods
  module Extractors
    # The tasks a loaded Rake application holds, keyed by where they were
    # defined.
    #
    # Source says where a `task` call sits; when its name or prerequisites are
    # computed, only the application that ran the file knows what the call
    # defined. A task is located by the source location of its actions, which
    # Rake always has, and by `Rake::Task#locations`, which it has only when
    # `Rake::TaskManager.record_task_metadata` was on (`rake -T`). In a process
    # that never loaded Rake, or loaded no tasks, the index is empty.
    #
    # A resident process keeps the application it booted with. After an edit
    # this index describes the old file, so callers use it only for what the
    # current source cannot state.
    #
    # @example
    #   RakeRuntimeIndex.current.tasks_at('/app/lib/tasks/sync.rake', 3, 3)
    #   # => [{ name: "sync:widgets", prerequisites: ["environment"], arguments: [], description: nil, kind: :task }]
    class RakeRuntimeIndex
      # @return [RakeRuntimeIndex] over `Rake.application`, empty when Rake is not loaded
      def self.current
        new(defined?(::Rake) && ::Rake.respond_to?(:application) ? ::Rake.application : nil)
      end

      # @param application [Rake::Application, nil]
      def initialize(application)
        @sites = Hash.new { |hash, file| hash[file] = [] }
        @real_paths = {}
        Array(application&.tasks).each { |task| index_task(task) }
      end

      # @return [Boolean] true when at least one loaded task has a known location
      def available?
        !@sites.empty?
      end

      # @param file [String] absolute path of a rake file
      # @param first_line [Integer] first line of the defining call
      # @param last_line [Integer] line its block opens on
      # @return [Array<Hash>] the tasks defined in that range, sorted by name:
      #   +{ name:, prerequisites:, arguments:, description:, kind: }+
      def tasks_at(file, first_line, last_line)
        return [] unless available?

        @sites.fetch(real_path(file), [])
              .select { |line, _| line.between?(first_line, last_line) }
              .map(&:last).uniq.sort_by { |task| task[:name] }
      end

      private

      def index_task(task)
        facts = facts_for(task)
        sites_of(task).each { |file, line| @sites[real_path(file)] << [line, facts] }
      rescue StandardError
        # A task object that cannot describe itself is left out of the index.
        nil
      end

      def facts_for(task)
        {
          name: task.name.to_s,
          prerequisites: task.prerequisites.map(&:to_s),
          arguments: task.arg_names.map(&:to_s),
          description: task.full_comment,
          kind: kind_of(task)
        }
      end

      def kind_of(task)
        return :multitask if task.is_a?(::Rake::MultiTask)

        task.is_a?(::Rake::FileTask) ? :file : :task
      end

      def sites_of(task)
        actions = task.actions.filter_map { |action| action.source_location if action.respond_to?(:source_location) }
        actions + task.locations.filter_map { |location| parse_location(location) }
      end

      # "path/to/file.rake:12:in `block in <top>'" => ["path/to/file.rake", 12]
      def parse_location(location)
        path, _, line = location.to_s.split(':in ', 2).first.rpartition(':')
        [path, Integer(line, 10)] unless path.empty?
      rescue ArgumentError
        nil
      end

      def real_path(file)
        @real_paths[file] ||= begin
          File.realpath(file)
        rescue SystemCallError
          File.expand_path(file)
        end
      end
    end
  end
end
