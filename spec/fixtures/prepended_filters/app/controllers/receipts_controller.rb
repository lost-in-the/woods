# frozen_string_literal: true

# Declaring the same filter again moves it: the later prepend, with its
# narrower scope, is the one Rails keeps.
class ReceiptsController < ApplicationController
  before_action :stamp_receipt
  before_action :load_receipt
  prepend_before_action :stamp_receipt, only: :show

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def stamp_receipt
    @stamp = trace(:stamp_receipt)
  end

  def load_receipt
    @receipt = trace(:load_receipt)
  end
end
