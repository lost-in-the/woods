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
    end
  end
end
