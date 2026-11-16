# frozen_string_literal: true

# The concern's prepended filter is included before this class declares its own.
class EarlyAuditsController < ApplicationController
  include Audited

  before_action :load_report

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def load_report
    @report = trace(:load_report)
  end
end
