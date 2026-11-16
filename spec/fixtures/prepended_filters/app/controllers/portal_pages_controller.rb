# frozen_string_literal: true

# Skips an inherited prepended filter for every action.
class PortalPagesController < PortalController
  skip_before_action :require_session
end
