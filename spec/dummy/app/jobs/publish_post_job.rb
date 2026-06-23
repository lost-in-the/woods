# frozen_string_literal: true

# A trivial job so the job extractor has a unit to produce.
class PublishPostJob < ActiveJob::Base
  def perform(post)
    post.update(status: 1)
  end
end
