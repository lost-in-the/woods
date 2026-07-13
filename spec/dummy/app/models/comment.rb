# frozen_string_literal: true

# A comment on a post. Belongs to Post and (optionally) User; its
# `after_create` callback has mailer-delivery and record-creation side
# effects the CallbackAnalyzer can detect.
class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user, optional: true
  has_many :notifications, as: :notifiable, dependent: :destroy

  validates :body, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_post, ->(post) { where(post_id: post.id) }

  after_create :notify_author

  # A short excerpt of the body for listings.
  def excerpt(limit = 60)
    body.to_s[0, limit]
  end

  private

  def notify_author
    NotificationMailer.comment_posted(self).deliver_later
    Notification.create!(user: post.user, notifiable: self) if post.user
  end
end
