# frozen_string_literal: true

# Cleans up a comment then fans out. Exercises retry_on/discard_on
# metadata and a job-to-job `perform_later` enqueue edge.
class ModerationJob < ActiveJob::Base
  queue_as :default

  retry_on StandardError, wait: 30.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(comment)
    comment.update(body: comment.body.to_s.strip)
    NotifyFollowersJob.perform_later(comment.post)
  end
end
