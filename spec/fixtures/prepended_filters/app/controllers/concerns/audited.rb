# frozen_string_literal: true

module Audited
  extend ActiveSupport::Concern

  included do
    prepend_before_action :start_audit
  end

  private

  def start_audit
    @audit = trace(:start_audit)
  end
end
