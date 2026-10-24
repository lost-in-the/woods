# frozen_string_literal: true

require 'set'
require_relative 'builder'
require_relative 'lifecycle_hops'

module Woods
  module Diagrams
    # A model event's callback chain as a `sequenceDiagram`, from the resolved
    # chain the extractor published. Depth 0 is the chain itself, as Woods
    # Map's Lifecycle tab draws it: the app calls each step on the model, an
    # async step hands off to its job or mailer, numbered by `autonumber`.
    # Depth 1 and 2 follow those hand-offs into the jobs and mailers they
    # reach ({LifecycleHops}). Only callbacks whose method the model's source
    # or an inlined concern defines are steps; framework callbacks are counted
    # in the details, not drawn.
    class Lifecycle < Builder
      KIND = 'lifecycle'
      OPTIONS = %w[event].freeze
      EVENTS = %w[create update destroy].freeze

      # Participants plus messages (R-4).
      SEQUENCE_BUDGET = 150

      # Chain order per event: the callback types that fire, in sequence.
      ORDER = {
        'create' => %w[before_validation after_validation before_save before_create after_create after_save
                       after_commit after_create_commit after_save_commit],
        'update' => %w[before_validation after_validation before_save before_update after_update after_save
                       after_commit after_update_commit after_save_commit],
        'destroy' => %w[before_destroy after_destroy after_commit after_destroy_commit]
      }.freeze

      # Framework callbacks the chain carries but nobody wrote.
      INTERNAL = /\A(_|autosave_associated_records_for_|#<)/
      DEFINITION = /^\s*def\s+(?:self\.)?([a-z_]\w*[?!=]?)/

      # One step of the chain.
      Step = Struct.new(:type, :callback, :side_effects, keyword_init: true) do
        # @return [Boolean] whether it hands work to another process
        def async?
          async_targets.any?
        end

        # @return [String, nil] where its work runs: the first job, else the first mailer
        def async_target
          async_targets.first
        end

        # @return [Array<String>] jobs, then mailers
        def async_targets
          effects = side_effects || {}
          Array(effects['jobs_enqueued']) + Array(effects['mailers_triggered'])
        end

        # @return [Array<Hash>] the operations Woods analysed in the callback
        def operations
          Array((side_effects || {})['operations'])
        end
      end

      private

      def prepare
        @unit = unit_of(%w[model])
        @event = choice('event', EVENTS, 'create')
        @callbacks, @framework = own_and_framework_callbacks
        @steps = chain
        @targets = @steps.filter_map(&:async_target).uniq
        @hops = LifecycleHops.new(@source, @steps, @targets, @depth)
      end

      def budget
        SEQUENCE_BUDGET
      end

      # @return [Integer] participants plus messages
      def size
        2 + @hops.participants.size + @steps.size + @hops.messages.size
      end

      def refusal_text
        return nil unless size > SEQUENCE_BUDGET

        "#{size} participants and messages is over the sequence budget of #{SEQUENCE_BUDGET}"
      end

      def extra_details
        { 'event' => @event, 'steps' => @steps.size, 'framework_callbacks' => @framework.size,
          'participants' => @hops.participants, 'followed' => @hops.followed, 'unfollowed' => @hops.unfollowed }
      end

      def mermaid
        lines = ['sequenceDiagram', '  autonumber', '  participant App', "  participant M as #{@unit['identifier']}"]
        @hops.participants.each_with_index { |target, i| lines << "  participant A#{i} as #{target}" }
        @steps.each do |s|
          lines << if s.async?
                     "  M-)A#{@targets.index(s.async_target)}: #{s.callback}"
                   else
                     "  App->>M: #{s.type} #{s.callback}"
                   end
        end
        (lines + @hops.messages).join("\n")
      end

      # The callbacks whose method the model or an inlined concern defines, and the rest (framework ones).
      def own_and_framework_callbacks
        defined = @unit['source_code'].to_s.scan(DEFINITION).flatten.to_set |
                  @source.concern_methods(@unit).values.flatten.to_set
        all = Array(@unit.dig('metadata', 'callbacks')).reject { |cb| cb['filter'].to_s.match?(INTERNAL) }
        all.partition { |cb| defined.include?(cb['filter'].to_s) }
      end

      def chain
        ORDER.fetch(@event).flat_map { |type| @callbacks.select { |cb| fires?(cb, type) } }.map do |cb|
          Step.new(type: cb['type'].to_s, callback: cb['filter'].to_s, side_effects: cb['side_effects'])
        end
      end

      def fires?(callback, type)
        return false unless callback['type'].to_s == type

        on = Array(callback.dig('conditions', 'on')).map(&:to_s)
        on.empty? || on.include?(@event)
      end
    end
  end
end
