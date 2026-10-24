# frozen_string_literal: true

class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  include SignedIn

  before_action :set_locale
  before_action :track_visit, except: :health

  private

  def set_locale; end

  def track_visit; end
end
