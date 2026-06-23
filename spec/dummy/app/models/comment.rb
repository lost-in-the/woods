# frozen_string_literal: true

# A comment on a post. Belongs to Post; gives the dependency graph an edge.
class Comment < ApplicationRecord
  belongs_to :post

  validates :body, presence: true
end
