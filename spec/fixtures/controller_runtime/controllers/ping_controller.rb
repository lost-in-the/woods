# frozen_string_literal: true

class PingController < ActionController::Metal
  include AbstractController::Callbacks

  before_action :stamp

  def index
    self.response_body = 'pong'
  end

  private

  def stamp = nil
end
