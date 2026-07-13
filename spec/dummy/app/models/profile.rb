# frozen_string_literal: true

# Per-user profile — the has_one side of User. Gives the graph a
# belongs_to edge back to the hub model.
class Profile < ApplicationRecord
  belongs_to :user

  validates :bio, length: { maximum: 500 }

  scope :with_bio, -> { where.not(bio: nil) }

  # A truncated bio for listings.
  def summary(limit = 120)
    bio.to_s[0, limit]
  end
end
