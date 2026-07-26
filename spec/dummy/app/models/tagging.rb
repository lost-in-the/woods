# frozen_string_literal: true

# Polymorphic join between Tag and any taggable (currently Post). No
# records are created in the booted spec, so the association only needs to
# be structurally valid for reflection.
class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :taggable, polymorphic: true

  scope :for_type, ->(type) { where(taggable_type: type) }
end
