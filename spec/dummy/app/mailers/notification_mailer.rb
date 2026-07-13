# frozen_string_literal: true

# Notification mail for comment activity and digests. Referenced from
# Comment's callback, jobs, and DigestBuilder so the mailer node gets
# multiple inbound edges.
class NotificationMailer < ApplicationMailer
  # Notify a post's author that a comment was posted.
  def comment_posted(comment)
    @comment = comment
    @post = comment.post
    mail(to: @post.user&.email, subject: "New comment on #{@post.title}")
  end

  # Weekly digest of recent posts for a user.
  def weekly_digest(user)
    @user = user
    @posts = Post.recent.limit(5)
    mail(to: user.email, subject: 'Your weekly digest')
  end
end
