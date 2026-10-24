# frozen_string_literal: true

require 'json'
require 'set'

module Woods
  module Diagrams
    # The async hops of a lifecycle (depth 1 and 2), from flow data assembled
    # over the published units: each job or mailer the chain hands work to is
    # followed into its own entry (a job's `#perform`, a mailer's action), and
    # that entry's operations become messages. A call is a message to itself;
    # an enqueue (`perform_later`) or a delivery (`deliver_later`,
    # `deliver_now`) hands off to the next participant, which the next depth
    # follows in turn. The last depth draws its hand-offs without following
    # them. A mailer whose action cannot be told (no `mailer_action` and more
    # than one action) is drawn but not followed, and named in the details.
    class LifecycleHops
      # Participant ids are A0, A1…; depth 0 numbers them as the chain reaches them.
      # @param source [Source]
      # @param steps [Array<Lifecycle::Step>] the chain
      # @param targets [Array<String>] the chain's async participants, in order
      # @param depth [Integer] 0 to 2
      def initialize(source, steps, targets, depth)
        @source = source
        @participants = targets.dup
        @messages = []
        @followed = []
        @unfollowed = []
        walk(steps, targets, depth)
      end

      # @return [Array<String>] every participant after M, in id order
      attr_reader :participants
      # @return [Array<String>] message lines after the chain's own
      attr_reader :messages
      # @return [Array<String>] the entries followed, in order
      attr_reader :followed
      # @return [Array<String>] participants that could not be followed
      attr_reader :unfollowed

      private

      def walk(steps, targets, depth)
        return if depth.zero?

        queue = targets.map { |target| [target, entry_for(target, chain_operations(steps, target)), 1] }
        seen = Set.new
        until queue.empty?
          label, entry, level = queue.shift
          next @unfollowed << label if entry.nil?
          next unless seen.add?(entry)

          @followed << entry
          follow(label, entry, level, depth, queue)
        end
        @unfollowed.uniq!
      end

      def follow(label, entry, level, depth, queue)
        from = "A#{@participants.index(label)}"
        operations(entry).each do |op|
          target, entry_next, text = handoff(op)
          if target
            @participants << target unless @participants.include?(target)
            @messages << "  #{from}-)A#{@participants.index(target)}: #{sanitize(text)}"
            queue << [target, entry_next, level + 1] if level < depth
          elsif op['type'] == 'call'
            @messages << "  #{from}->>#{from}: #{sanitize(call_text(op))}"
          end
        end
      end

      # @return [Array(String, String, String), nil] participant, its entry and the message for a hand-off
      def handoff(operation)
        if operation['mailer_action'].to_s.include?('#')
          mailer, action = operation['mailer_action'].split('#', 2)
          [mailer, operation['mailer_action'], "#{action} (#{operation['method']})"]
        elsif operation['type'] == 'async' && operation['target']
          [operation['target'], "#{operation['target']}#perform", operation['method'].to_s]
        end
      end

      def call_text(operation)
        target = operation['target'].to_s
        target.empty? || target == 'self' ? operation['method'].to_s : "#{target}.#{operation['method']}"
      end

      # The operations of an entry's own step, conditionals flattened in order.
      def operations(entry)
        doc = JSON.parse(JSON.generate(@source.flow_assembler.assemble(entry, max_depth: 1).to_h))
        step = Array(doc['steps']).find { |s| s['unit'] == entry }
        flatten(Array(step&.dig('operations')))
      rescue StandardError
        []
      end

      def flatten(ops)
        ops.grep(Hash).flat_map do |op|
          nested = op.values.select { |value| value.is_a?(Array) && value.all?(Hash) && value.any? }
          [op] + nested.flat_map { |list| flatten(list) }
        end
      end

      def chain_operations(steps, target)
        flatten(steps.select { |step| step.async_target == target }.flat_map(&:operations))
      end

      # A job's `#perform`; a mailer's action from the chain's own delivery, or its only action.
      def entry_for(target, ops)
        case @source.type_of(target)
        when 'job' then "#{target}#perform"
        when 'mailer'
          action = ops.find { |op| op['mailer_action'].to_s.start_with?("#{target}#") }&.dig('mailer_action')
          action || only_action(target)
        end
      end

      def only_action(mailer)
        actions = Array(@source.unit(mailer, type: 'mailer')&.dig('metadata', 'actions'))
        actions.one? ? "#{mailer}##{actions.first}" : nil
      end

      # Mermaid ends a message at a newline and reads `#…;` as an entity.
      def sanitize(text)
        text.to_s.gsub(/[;#\r\n]/, ' ').squeeze(' ').strip
      end
    end
  end
end
