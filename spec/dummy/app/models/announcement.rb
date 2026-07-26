# frozen_string_literal: true

# STI subclass of Post (uses the posts table's `type` column). Gives the
# extraction an inheritance shape beyond ApplicationRecord.
class Announcement < Post
  scope :active, -> { where(status: 1) }

  # Announcements are always considered pinned in listings.
  def pinned?
    true
  end
end
