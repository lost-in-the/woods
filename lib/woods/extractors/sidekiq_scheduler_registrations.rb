# frozen_string_literal: true

require_relative 'schedule_literals'

module Woods
  module Extractors
    # Reads sidekiq-scheduler schedules set from Ruby source without running it:
    #
    # - `Sidekiq.schedule = { name => definition, ... }` with a literal Hash
    # - `Sidekiq.set_schedule(name, definition)` with a literal definition (the
    #   dynamic-schedule API)
    #
    # The receiver may be `Sidekiq`, `Sidekiq::Scheduler`, or
    # `SidekiqScheduler::Scheduler` (optionally `.instance`). A computed
    # schedule (`Sidekiq.schedule = YAML.load_file(...)`) is skipped.
    #
    # @example
    #   program = ScheduleLiterals.parse("Sidekiq.set_schedule('beat', { 'every' => '1m', 'class' => 'BeatJob' })")
    #   SidekiqSchedulerRegistrations.collect(program).first.values_at(:name, :job_class, :registration)
    #   # => ["beat", "BeatJob", :set_schedule]
    module SidekiqSchedulerRegistrations
      RECEIVERS = %w[Sidekiq Sidekiq::Scheduler SidekiqScheduler::Scheduler].freeze

      module_function

      # @param program [Prism::Node] a parsed source
      # @return [Array<Hash>] one {ScheduleLiterals.entry} per schedule in source order,
      #   with `:line` and `:registration` (:schedule or :set_schedule)
      def collect(program)
        entries = []
        ScheduleLiterals.each_node(program) do |node|
          next unless node.is_a?(Prism::CallNode) && scheduler?(node.receiver)

          case node.name
          when :schedule= then entries.concat(schedule_entries(node))
          when :set_schedule then entries.concat(dynamic_entries(node))
          end
        end
        entries
      end

      def scheduler?(receiver)
        receiver = receiver.receiver if receiver.is_a?(Prism::CallNode) && receiver.name == :instance
        (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) &&
          RECEIVERS.include?(receiver.slice.delete_prefix('::'))
      end

      def schedule_entries(call)
        ScheduleLiterals.assocs(call.arguments&.arguments&.first).filter_map do |name_node, definition|
          next unless ScheduleLiterals.hash_node?(definition)

          ScheduleLiterals.entry(definition, name_node: name_node)
                          .merge(line: name_node.location.start_line, registration: :schedule)
        end
      end

      def dynamic_entries(call)
        name_node, definition = call.arguments&.arguments
        return [] unless name_node && ScheduleLiterals.hash_node?(definition)

        [ScheduleLiterals.entry(definition, name_node: name_node)
                         .merge(line: call.location.start_line, registration: :set_schedule)]
      end

      private_class_method :scheduler?, :schedule_entries, :dynamic_entries
    end
  end
end
