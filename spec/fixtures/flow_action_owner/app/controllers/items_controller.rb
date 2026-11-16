# frozen_string_literal: true

# Each action's dispatched body differs from its first local definition, except #show.
class ItemsController < ApplicationController
  include IncludedShow
  prepend ReplacedCreate
  prepend SuperUpdate

  before_action :load_item

  def show
    LocalShowJob.perform_later
  end

  def create
    ShadowedCreateJob.perform_later
  end

  def update
    LocalUpdateJob.perform_later
  end

  def destroy
    FirstDestroyJob.perform_later
  end

  def destroy # rubocop:disable Lint/DuplicateMethods
    SecondDestroyJob.perform_later
  end

  private

  def load_item; end
end
