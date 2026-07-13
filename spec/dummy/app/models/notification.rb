# frozen_string_literal: true

# An in-app notification. Second polymorphic association in the graph
# (notifiable: comments and posts) plus a belongs_to back to User.
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true

  scope :unread, -> { where(read: false) }
  scope :recent, -> { order(created_at: :desc) }

  # Mark the notification as read.
  def mark_read!
    update!(read: true)
  end
end
