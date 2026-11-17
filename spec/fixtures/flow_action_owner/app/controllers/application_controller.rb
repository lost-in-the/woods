# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Conditions the exclusive same-line definitions in ItemsController branch on.
  def self.on?
    true
  end

  def self.off?
    false
  end

  def archive
    BaseArchiveJob.perform_later
  end
end
