# frozen_string_literal: true

# A prepended filter declared after ordinary ones runs before all of them,
# the inherited set_locale included.
class LedgersController < ApplicationController
  before_action :load_ledger
  before_action :check_quota, only: :show
  prepend_before_action :authenticate_clerk

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def authenticate_clerk
    @clerk = trace(:authenticate_clerk)
  end

  def load_ledger
    @ledger = trace(:load_ledger)
  end

  def check_quota
    @quota = trace(:check_quota)
  end
end
