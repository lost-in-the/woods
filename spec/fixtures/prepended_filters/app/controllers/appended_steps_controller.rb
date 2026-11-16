# frozen_string_literal: true

# append_before_action is before_action; the prepend: option is prepend_before_action.
class AppendedStepsController < ApplicationController
  before_action :first_step
  append_before_action :second_step
  before_action :urgent_step, prepend: true

  def index
    head(:ok)
  end

  def show
    head(:ok)
  end

  private

  def first_step
    @first = trace(:first_step)
  end

  def second_step
    @second = trace(:second_step)
  end

  def urgent_step
    @urgent = trace(:urgent_step)
  end
end
