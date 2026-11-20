# frozen_string_literal: true

# Skips inherited prepended filters for some actions. warm_cache keeps its
# inherited only: %i[index show] and gains a skip everywhere but index:
# Rails runs it where both scopes admit the action, on index alone.
class PortalPreviewsController < PortalController
  skip_before_action :require_session, only: :show
  skip_before_action :warm_cache, except: :index
end
