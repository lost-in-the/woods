# frozen_string_literal: true

# A blog post. Exercises associations, scopes, validations, and a callback so
# the extraction path has real behavioral metadata to resolve.
#
# No `enum` declaration: the macro's signature differs across the supported
# range (positional `enum :status, {…}` is 7.0+; keyword `enum status: {…}` is
# rejected on 8.0), and the booted-app test doesn't assert enum behaviour. The
# `status` integer column stays in the schema.
class Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }

  before_save :normalize_title

  def normalize_title
    self.title = title.to_s.strip
  end
end
