# frozen_string_literal: true

# Recency helpers shared by trackable records. A second concern so the
# extraction sees more than one `include` edge shape.
module Trackable
  extend ActiveSupport::Concern

  included do
    scope :recently_created, -> { order(created_at: :desc) }
  end

  # Whether the record was created within the last week.
  def created_recently?
    created_at.present? && created_at > 7.days.ago
  end
end
