# frozen_string_literal: true

# Prepended around and after filters beside ordinary ones. After filters run
# in the reverse of their chain order.
class InstrumentsController < ApplicationController
  before_action :load_instrument
  around_action :with_lock
  after_action :record_view
  after_action :record_audit, only: :show
  prepend_after_action :flush_metrics
  prepend_around_action :with_timing, except: :index

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def load_instrument
    @instrument = trace(:load_instrument)
  end

  def with_lock
    @lock = trace(:with_lock)
    yield
  end

  def with_timing
    @timing = trace(:with_timing)
    yield
  end

  def record_view
    trace(:record_view)
  end

  def record_audit
    trace(:record_audit)
  end

  def flush_metrics
    trace(:flush_metrics)
  end
end
