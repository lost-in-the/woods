# frozen_string_literal: true

require_relative 'schedule_literals'

module Woods
  module Extractors
    # Reads Sidekiq Enterprise periodic registrations from Ruby source without
    # running it. `configure_server` blocks only execute inside a Sidekiq
    # server process, so the registrations are invisible to a booted rake task.
    #
    # A registration is `<param>.register(cron, job_class, options)` where
    # `<param>` is the block parameter of a `periodic` block: named, `_1`, or `it`.
    #
    # @example
    #   PeriodicRegistrations.read("config.periodic { |m| m.register('0 * * * *', 'SweepWorker') }")
    #   # => [{ cron: '0 * * * *', cron_source: nil, job_class: 'SweepWorker', options: {}, line: 1 }]
    module PeriodicRegistrations
      # Raised when the source does not parse.
      ParseError = ScheduleLiterals::ParseError

      # Receiver names for a block's numbered and `it` parameters.
      IMPLICIT_PARAMETERS = %i[_1 it].freeze

      module_function

      # @param source [String] Ruby source
      # @return [Array<Hash>] registrations in source order; `:job_class` is nil
      #   when the class argument is not a literal constant name, and `:cron` is
      #   nil with the argument's source in `:cron_source` when the cron is computed
      # @raise [ParseError] when Prism reports a syntax error
      def read(source)
        collect(ScheduleLiterals.parse(source))
      end

      # @param program [Prism::Node] a parsed source
      # @return [Array<Hash>] as {.read}
      def collect(program)
        calls = []
        collect_periodic_blocks(program, calls)
        calls.map { |call| registration(call) }
      end

      def collect_periodic_blocks(node, calls)
        if periodic_block?(node)
          name = block_parameter(node.block)
          collect_registrations(node.block.body, name, calls) if name
          return
        end

        node.compact_child_nodes.each { |child| collect_periodic_blocks(child, calls) }
      end

      def collect_registrations(node, receiver_name, calls)
        return unless node
        return if IMPLICIT_PARAMETERS.include?(receiver_name) && rebinds_implicit_parameter?(node)

        calls << node if registration_call?(node, receiver_name)
        node.compact_child_nodes.each { |child| collect_registrations(child, receiver_name, calls) }
      end

      # `_1` and `it` inside a nested block belong to that block.
      def rebinds_implicit_parameter?(node)
        node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
      end

      def periodic_block?(node)
        node.is_a?(Prism::CallNode) && node.name == :periodic && node.block.is_a?(Prism::BlockNode)
      end

      def block_parameter(block)
        parameters = block.parameters
        case parameters
        when Prism::NumberedParametersNode then :_1
        when Prism::ItParametersNode then :it
        when Prism::BlockParametersNode
          first = parameters.parameters&.requireds&.first
          first.name if first.is_a?(Prism::RequiredParameterNode)
        end
      end

      def registration_call?(node, receiver_name)
        return false unless node.is_a?(Prism::CallNode) && node.name == :register

        receiver = node.receiver
        case receiver
        when Prism::LocalVariableReadNode then receiver.name == receiver_name
        when Prism::ItLocalVariableReadNode then receiver_name == :it
        else false
        end
      end

      def registration(call)
        cron, job_class, options = call.arguments&.arguments || []
        literal_cron = cron.is_a?(Prism::StringNode)
        {
          cron: literal_cron ? cron.unescaped : nil,
          cron_source: literal_cron ? nil : cron&.slice,
          job_class: ScheduleLiterals.class_name(job_class),
          options: ScheduleLiterals.literal_hash(options),
          line: call.location.start_line
        }
      end

      private_class_method :collect_periodic_blocks, :collect_registrations, :periodic_block?,
                           :rebinds_implicit_parameter?, :block_parameter, :registration_call?, :registration
    end
  end
end
