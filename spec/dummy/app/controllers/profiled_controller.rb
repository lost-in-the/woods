# frozen_string_literal: true

# A source file owns both a resolved controller and a whole-file cache profile.
class ProfiledController < ApplicationController
  def index
    @count = Rails.cache.fetch('profiled-post-count') { Post.count }
  end
end
