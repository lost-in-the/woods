# frozen_string_literal: true

# Its own prepended filter runs before the inherited prepended ones.
class PortalDocumentsController < PortalController
  before_action :load_document, except: :index
  prepend_before_action :throttle

  private

  def load_document
    @document = trace(:load_document)
  end

  def throttle
    @throttled = trace(:throttle)
  end
end
