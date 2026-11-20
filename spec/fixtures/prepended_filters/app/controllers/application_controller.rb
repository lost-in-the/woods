# frozen_string_literal: true

# Every filter records its name in the request env as it runs, so a spec can
# read the order Rails ran them in.
class ApplicationController < ActionController::Base
  before_action :set_locale

  private

  def trace(name)
    (request.env['filter_probe.trace'] ||= []) << name.to_s
  end

  def set_locale
    @locale = trace(:set_locale)
  end
end
