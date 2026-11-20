# frozen_string_literal: true

# Several names in one prepend call, a block, a lambda, and scoped prepends.
class BatchesController < ApplicationController
  before_action :load_batch
  prepend_before_action :alpha, :beta
  prepend_before_action { trace("proc:#{__LINE__}") }
  prepend_before_action ->(controller) { controller.send(:trace, "proc:#{__LINE__}") }, only: :show
  prepend_before_action :scoped_only, only: :show
  prepend_before_action :scoped_except, except: :show
  prepend_before_action :scoped_if, if: :allowed?

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def load_batch
    @batch = trace(:load_batch)
  end

  def alpha
    @alpha = trace(:alpha)
  end

  def beta
    @beta = trace(:beta)
  end

  def scoped_only
    @only = trace(:scoped_only)
  end

  def scoped_except
    @except = trace(:scoped_except)
  end

  def scoped_if
    @if = trace(:scoped_if)
  end

  def allowed?
    true
  end
end
