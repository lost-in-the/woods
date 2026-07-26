# frozen_string_literal: true

# Call-style service object: publishes a post and schedules the publish
# job. Gives service extraction a `self.call` entry point with model and
# job dependencies.
class PostPublisher
  # Publish the given post.
  #
  # @param post [Post]
  # @return [Post]
  def self.call(post)
    new(post).call
  end

  def initialize(post)
    @post = post
  end

  # Mark the post published and enqueue the follow-up job.
  def call
    @post.update(status: 1)
    PublishPostJob.perform_later(@post)
    @post
  end
end
