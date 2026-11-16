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
  prepend ExportOverride
  prepend SuperCalls

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

  # Two definitions on one line: Ruby keeps the later.
  # rubocop:disable-next Style/SingleLineMethods, Style/Semicolon, Lint/DuplicateMethods
  def summary; FirstSummaryJob.perform_later; end; def summary; SecondSummaryJob.perform_later; end

  def export
    LocalExportJob.perform_later
  end

  # The controller's definition, then a nested module's, on one line.
  # rubocop:disable-next Style/SingleLineMethods, Style/Semicolon
  def preview; LocalPreviewJob.perform_later; end; module Extra; def preview; ExtraPreviewJob.perform_later; end; end

  def twice
    LocalTwiceJob.perform_later
  end

  def compact
    LocalCompactJob.perform_later
  end

  def gated
    LocalGatedJob.perform_later
  end

  def locked
    LocalLockedJob.perform_later
  end

  private

  def gate_open?
    true
  end

  def load_item; end
end
