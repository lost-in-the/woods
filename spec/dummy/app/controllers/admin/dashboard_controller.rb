# frozen_string_literal: true

module Admin
  # Namespaced dashboard so route extraction covers a `namespace` block.
  class DashboardController < BaseController
    def index
      @recent_posts = Post.recent.limit(10)
      @user_count = User.count
    end
  end
end
