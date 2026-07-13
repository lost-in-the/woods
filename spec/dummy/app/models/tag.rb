# frozen_string_literal: true

# A content tag. Reaches posts through the polymorphic Tagging join
# (has_many :through with source_type), and shares Sluggable with Post so
# concern inlining shows up on two models.
class Tag < ApplicationRecord
  include Sluggable

  has_many :taggings, dependent: :destroy
  has_many :posts, through: :taggings, source: :taggable, source_type: 'Post'

  validates :name, presence: true, uniqueness: true

  scope :alphabetical, -> { order(:name) }
  scope :used, -> { joins(:taggings).distinct }

  # Display label for views.
  def label
    name.to_s.strip
  end
end
