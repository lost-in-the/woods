# frozen_string_literal: true

# Full RESTful controller so the controller + route extractors have
# something to resolve, including strong params and route-helper
# navigation (redirect_to) edges.
class PostsController < ApplicationController
  def index
    @posts = Post.recent
  end

  def show
    @post = Post.find(params[:id])
  end

  def new
    @post = Post.new
  end

  def create
    @post = Post.create(title: params[:title])
    redirect_to posts_path
  end

  def edit
    @post = Post.find(params[:id])
  end

  def update
    @post = Post.find(params[:id])
    if @post.update(post_params)
      redirect_to post_path(@post)
    else
      render :edit
    end
  end

  def destroy
    @post = Post.find(params[:id])
    @post.destroy
    redirect_to posts_path
  end

  private

  def post_params
    params.require(:post).permit(:title, :status, :slug, :user_id)
  end
end
