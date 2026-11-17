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

  def handed
    LocalHandedJob.perform_later
  end

  # Each line defines an action twice in exclusive branches; Ruby installs one.
  # rubocop:disable all
  if on? then def if_on; Flip::A.perform_later; end else def if_on; Flip::B.perform_later; end end
  if off? then def if_off; Flip::A.perform_later; end else def if_off; Flip::B.perform_later; end end
  on? ? (def tern_on; Flip::A.perform_later; end) : (def tern_on; Flip::B.perform_later; end)
  off? ? (def tern_off; Flip::A.perform_later; end) : (def tern_off; Flip::B.perform_later; end)
  case on? when true then def case_on; Flip::A.perform_later; end else def case_on; Flip::B.perform_later; end end
  case off? when true then def case_off; Flip::A.perform_later; end else def case_off; Flip::B.perform_later; end end
  on? && (def andor_on; Flip::A.perform_later; end) || (def andor_on; Flip::B.perform_later; end)
  off? && (def andor_off; Flip::A.perform_later; end) || (def andor_off; Flip::B.perform_later; end)
  def mod_on; Flip::A.perform_later; end if on?; def mod_on; Flip::B.perform_later; end unless on?
  def mod_off; Flip::A.perform_later; end if off?; def mod_off; Flip::B.perform_later; end unless off?
  begin; on? && raise; def resc_on; Flip::A.perform_later; end; rescue; def resc_on; Flip::B.perform_later; end; end
  begin; off? && raise; def resc_off; Flip::A.perform_later; end; rescue; def resc_off; Flip::B.perform_later; end; end
  # rubocop:enable all

  private

  def gate_open?
    true
  end

  def handed?
    true
  end

  def record(value); end

  def load_item; end
end
