# frozen_string_literal: true

# Base controller. The before_action gives every controller a shared
# filter and a code_reference edge to User.
class ApplicationController < ActionController::Base
  before_action :set_current_user

  private

  def set_current_user
    @current_user = User.find_by(id: session[:user_id])
  end
end
