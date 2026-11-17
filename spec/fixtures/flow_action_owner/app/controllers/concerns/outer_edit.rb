# frozen_string_literal: true

module OuterEdit
  def edit
    OuterEditJob.perform_later
    super
  end
end
