# frozen_string_literal: true

# A blog post. Exercises associations, scopes, validations, concern
# inlining (Sluggable), and callbacks with detectable side effects (a
# `self.col =` write plus a `perform_later` job enqueue).
#
# No `enum` declaration: the macro's signature differs across the supported
# range (positional `enum :status, {…}` is 7.0+; keyword `enum status: {…}` is
# rejected on 8.0), and the booted-app test doesn't assert enum behaviour. The
# `status` integer column stays in the schema.
class Post < ApplicationRecord
  include Sluggable

  belongs_to :user, optional: true
  has_many :comments, dependent: :destroy
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :published, -> { where(status: 1) }
  scope :drafts, -> { where(status: 0) }

  before_save :normalize_title
  after_save :schedule_publish

  def normalize_title
    self.title = title.to_s.strip
  end

  # Whether the post has been published.
  def published?
    status.to_i == 1
  end

  # A short preview of the title for listings.
  def preview(limit = 80)
    title.to_s[0, limit]
  end

  private

  def schedule_publish
    PublishPostJob.perform_later(self)
  end
end
