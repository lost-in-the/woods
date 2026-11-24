# frozen_string_literal: true

# A base controller whose prepended filters its subclasses inherit, declare
# around, or skip.
class PortalController < ApplicationController
  prepend_before_action :require_session
  prepend_before_action :warm_cache, only: %i[index show]
  before_action :load_portal

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  def edit
    head(:ok)
  end

  private

  def require_session
    @session_checked = trace(:require_session)
  end

  def warm_cache
    @cache = trace(:warm_cache)
  end

  def load_portal
    @portal = trace(:load_portal)
  end
end
