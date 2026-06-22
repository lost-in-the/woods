# frozen_string_literal: true

# A blog post. Exercises associations, scopes, validations, enums, and a
# callback so the extraction path has real behavioral metadata to resolve.
class Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  enum :status, { draft: 0, published: 1 } if respond_to?(:enum)

  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }

  before_save :normalize_title

  def normalize_title
    self.title = title.to_s.strip
  end
end
