# frozen_string_literal: true

class ArticlesController < ApplicationController
  before_action :set_article, only: %i[show edit]
  skip_before_action :track_visit, only: :index
  after_action :log_render, if: -> { request.format.html? }

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  def edit
    head(:ok)
  end

  def health
    head(:ok)
  end

  private

  def set_article; end

  def log_render; end
end
