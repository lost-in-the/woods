# frozen_string_literal: true

# Plain PORO decorator around Post so decorator extraction has a unit and
# a decoration edge.
class PostDecorator
  attr_reader :post

  def initialize(post)
    @post = post
  end

  # Cleaned-up title for display.
  def display_title
    post.title.to_s.strip
  end

  # Human-readable publication state.
  def status_label
    post.published? ? 'Published' : 'Draft'
  end

  # Number of comments on the post.
  def comment_count
    post.comments.size
  end
end
