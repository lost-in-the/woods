# frozen_string_literal: true

# Read-only user pages.
class UsersController < ApplicationController
  def show
    @user = User.find(params[:id])
    @posts = @user.posts.recent
  end
end
