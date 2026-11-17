# frozen_string_literal: true

module SuperUpdate
  def update
    PrependedUpdateJob.perform_later
    super
  end
end
