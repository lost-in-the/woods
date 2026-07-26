# frozen_string_literal: true

# Slug generation shared by Post and Tag. Exercises concern inlining, a
# callback registered from an `included` block, a concern-provided scope,
# and a `self.col =` write the CallbackAnalyzer can detect.
module Sluggable
  extend ActiveSupport::Concern

  included do
    before_validation :generate_slug

    scope :slugged, -> { where.not(slug: nil) }
  end

  # Derive a URL-safe slug from the record's title or name.
  def generate_slug
    self.slug = slug_source.to_s.downcase.strip.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
  end

  # The attribute the slug is derived from.
  def slug_source
    respond_to?(:title) ? title : name
  end
end
