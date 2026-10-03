# frozen_string_literal: true

require 'set'
require_relative 'schedule_literals'

module Woods
  module Extractors
    # Reads Sidekiq-Cron jobs registered from Ruby source without running it:
    #
    # - `Sidekiq::Cron::Job.create(name:, cron:, class:, ...)`
    # - `Sidekiq::Cron::Job.new(...).save`, directly or through a local that is saved
    # - `Sidekiq::Cron::Job.load_from_hash(!)` with a literal Hash of name => definition
    # - `Sidekiq::Cron::Job.load_from_array(!)` with a literal Array of definitions
    #
    # A computed argument (`load_from_hash(YAML.load_file(...))`) is skipped.
    #
    # @example
    #   program = ScheduleLiterals.parse("Sidekiq::Cron::Job.create(name: 'a', cron: '* * * * *', class: 'AJob')")
    #   SidekiqCronRegistrations.collect(program).first.values_at(:name, :job_class, :registration)
    #   # => ["a", "AJob", :create]
    module SidekiqCronRegistrations
      RECEIVER = 'Sidekiq::Cron::Job'

      LOADERS = {
        load_from_hash: :load_from_hash, load_from_hash!: :load_from_hash,
        load_from_array: :load_from_array, load_from_array!: :load_from_array
      }.freeze

      module_function

      # @param program [Prism::Node] a parsed source
      # @return [Array<Hash>] one {ScheduleLiterals.entry} per job in source order,
      #   with `:line` and `:registration` (:create, :new_save, :load_from_hash, :load_from_array)
      def collect(program)
        calls = registration_calls(program)
        calls.sort_by { |call| call.location.start_offset }.flat_map { |call| entries(call) }
      end

      def registration_calls(program)
        calls = []
        saved_news = []
        saved_locals = Set.new
        assigned_news = Hash.new { |hash, name| hash[name] = [] }

        ScheduleLiterals.each_node(program) do |node|
          case node
          when Prism::CallNode
            calls << node if job_call?(node, :create, *LOADERS.keys)
            next unless node.name == :save

            receiver = node.receiver
            saved_news << receiver if job_call?(receiver, :new)
            saved_locals << receiver.name if receiver.is_a?(Prism::LocalVariableReadNode)
          when Prism::LocalVariableWriteNode
            assigned_news[node.name] << node.value if job_call?(node.value, :new)
          end
        end

        calls + saved_news + saved_locals.flat_map { |name| assigned_news.fetch(name, []) }.uniq
      end

      def job_call?(node, *names)
        node.is_a?(Prism::CallNode) && names.include?(node.name) &&
          (node.receiver.is_a?(Prism::ConstantPathNode) || node.receiver.is_a?(Prism::ConstantReadNode)) &&
          node.receiver.slice.delete_prefix('::') == RECEIVER
      end

      def entries(call)
        argument = call.arguments&.arguments&.first
        case call.name
        when :create, :new
          return [] unless ScheduleLiterals.hash_node?(argument)

          registration = call.name == :create ? :create : :new_save
          [ScheduleLiterals.entry(argument).merge(line: call.location.start_line, registration: registration)]
        else
          loader_entries(argument, LOADERS.fetch(call.name))
        end
      end

      def loader_entries(argument, registration)
        definitions = if registration == :load_from_hash
                        ScheduleLiterals.assocs(argument).map { |key, value| [value, key] }
                      elsif argument.is_a?(Prism::ArrayNode)
                        argument.elements.map { |element| [element, nil] }
                      else
                        []
                      end
        definitions.filter_map do |definition, name_node|
          next unless ScheduleLiterals.hash_node?(definition)

          ScheduleLiterals.entry(definition, name_node: name_node)
                          .merge(line: definition.location.start_line, registration: registration)
        end
      end

      private_class_method :registration_calls, :job_call?, :entries, :loader_entries
    end
  end
end
