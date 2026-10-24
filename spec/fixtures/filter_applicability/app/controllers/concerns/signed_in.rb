# frozen_string_literal: true

module SignedIn
  extend ActiveSupport::Concern

  included do
    before_action :require_login, unless: :public_page?
  end

  private

  def require_login; end

  def public_page?
    false
  end
end
