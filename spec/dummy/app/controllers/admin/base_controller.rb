# frozen_string_literal: true

module Admin
  # Shared base for the admin namespace — adds a guard filter so the
  # extraction sees namespaced controller inheritance plus a before_action.
  class BaseController < ApplicationController
    before_action :require_admin

    private

    def require_admin
      redirect_to posts_path unless @current_user
    end
  end
end
