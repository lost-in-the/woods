# frozen_string_literal: true

# Nested comments controller (under posts). Exercises nested-resource
# routes, strong params, and redirect_to navigation edges.
class CommentsController < ApplicationController
  def create
    @post = Post.find(params[:post_id])
    @comment = @post.comments.create(comment_params)
    redirect_to post_path(@post)
  end

  def destroy
    @comment = Comment.find(params[:id])
    post = @comment.post
    @comment.destroy
    redirect_to post_path(post)
  end

  private

  def comment_params
    params.require(:comment).permit(:body, :user_id)
  end
end
