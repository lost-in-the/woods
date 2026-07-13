# frozen_string_literal: true

# Fans a post out to interested users. Exercises `queue_as`, a mailer
# deliver_later, and a Notification.create! side effect.
class NotifyFollowersJob < ActiveJob::Base
  queue_as :notifications

  def perform(post)
    return unless post.user

    NotificationMailer.weekly_digest(post.user).deliver_later
    Notification.create!(user: post.user, notifiable: post)
  end
end
