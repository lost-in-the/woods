# frozen_string_literal: true

# A forum member. Hub of the association graph: authors posts and
# comments, owns a profile and notifications. Its `before_save` callback
# writes a column (`self.email =`) so callback analysis has a side effect
# to detect.
class User < ApplicationRecord
  include Trackable

  has_many :posts, dependent: :nullify
  has_many :comments, dependent: :nullify
  has_one :profile, dependent: :destroy
  has_many :notifications, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :name, presence: true

  scope :alphabetical, -> { order(:name) }
  scope :with_posts, -> { joins(:posts).distinct }

  before_save :normalize_email

  # Display name for views and mailers.
  def display_name
    name.to_s.strip
  end

  # Count of notifications not yet read.
  def unread_notification_count
    notifications.unread.count
  end

  private

  def normalize_email
    self.email = email.to_s.downcase
  end
end
