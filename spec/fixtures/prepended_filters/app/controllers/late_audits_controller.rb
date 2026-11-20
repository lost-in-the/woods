# frozen_string_literal: true

# The concern's prepended filter is included after this class declares its own.
class LateAuditsController < ApplicationController
  before_action :load_report, except: :index

  include Audited

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
