# frozen_string_literal: true

# Instance-style service object: assembles a digest for a user and hands
# it to the mailer. Gives service extraction a second shape (instance
# `#build` rather than `self.call`).
class DigestBuilder
  def initialize(user)
    @user = user
  end

  # Build the digest payload and deliver it when there is content.
  #
  # @return [Hash]
  def build
    posts = Post.recent.limit(10)
    NotificationMailer.weekly_digest(@user).deliver_later if posts.any?
    { user: @user.email, post_titles: posts.map(&:title) }
  end
end
