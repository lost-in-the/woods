# frozen_string_literal: true

# Minimal RESTful controller so the controller + route extractors have
# something to resolve, including a route-helper navigation edge.
class PostsController < ApplicationController
  def index
    @posts = Post.recent
  end

  def show
    @post = Post.find(params[:id])
  end

  def create
    @post = Post.create(title: params[:title])
    redirect_to posts_path
  end
end
