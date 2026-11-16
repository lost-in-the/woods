# frozen_string_literal: true

# Each action's dispatched body differs from its first local definition, except #show.
# The last module prepended is the first Ruby calls.
class ItemsController < ApplicationController
  include IncludedShow
  prepend ReplacedCreate
  prepend SuperUpdate
  prepend InnerEdit
  prepend OuterEdit
  prepend InnerIndex
  prepend OuterIndex
  prepend PrependedArchive

  before_action :load_item

  def index
    LocalIndexJob.perform_later
  end

  def edit
    LocalEditJob.perform_later
  end

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
