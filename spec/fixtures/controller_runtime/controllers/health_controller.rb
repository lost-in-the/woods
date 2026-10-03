# frozen_string_literal: true

class HealthController < ActionController::Metal
  def show
    self.response_body = 'ok'
  end

  private

  def checks = []
end
