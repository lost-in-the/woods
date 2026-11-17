# frozen_string_literal: true

module InnerEdit
  def edit
    InnerEditJob.perform_later
  end
end
