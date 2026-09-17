# frozen_string_literal: true

class CallbacksController < ActionController::Base
  before_action(ENV['CALLBACK_KIND'] == 'lambda' ? -> { :first } : proc { :first }, only: :index)
  before_action(proc { :second }, if: -> { true }, unless: proc { false })
  before_action :check, if: :enabled?, unless: :disabled?

  def index
    head :ok
  end

  private

  def check; end

  def enabled?
    true
  end

  def disabled?
    false
  end
end
