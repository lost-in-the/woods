# frozen_string_literal: true

class LedgerReportsController < ActionController::Base
  attr_reader :ledger

  def show
    head :ok
  end
end
