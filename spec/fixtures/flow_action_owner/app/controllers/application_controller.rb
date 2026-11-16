# frozen_string_literal: true

class ApplicationController < ActionController::Base
  def archive
    BaseArchiveJob.perform_later
  end
end
