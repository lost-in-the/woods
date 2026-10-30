# frozen_string_literal: true

module Woods
  module SourceReferences
    # Class-body declarations whose literal symbol arguments name an
    # association, a callback method or a scope (#751 declaration spans).
    module Macros
      ASSOCIATION_MACROS = %w[belongs_to has_many has_one has_and_belongs_to_many].freeze
      CALLBACK_MACROS = (%w[validation save create update destroy commit rollback].flat_map do |event|
        %W[before_#{event} around_#{event} after_#{event}]
      end + %w[after_create_commit after_update_commit after_destroy_commit after_save_commit after_initialize
               after_find after_touch] +
        %w[before after around].flat_map do |kind|
          %W[#{kind}_action prepend_#{kind}_action append_#{kind}_action]
        end).uniq.freeze
      MACROS = (ASSOCIATION_MACROS + CALLBACK_MACROS + %w[scope]).freeze
      # Receiverless calls whose constant arguments are mixed into the caller.
      MIXIN_CALLS = %w[include extend prepend].freeze

      # `include`, `extend` and `prepend` of a constant written straight in the
      # call: the constant's span is tagged with which of the three it is. The
      # constant is still an ordinary reference for resolution; only the
      # published span learns the relationship.
      def mark_mixins(node)
        return unless @adapter.receiver(node).nil?

        name = @adapter.selector(node).to_s
        return unless MIXIN_CALLS.include?(name)

        @adapter.arguments(node).each { |argument| @mixins[argument] = name if @adapter.kind(argument) == :constant }
      end
    end
  end
end
