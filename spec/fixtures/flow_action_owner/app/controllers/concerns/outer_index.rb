# frozen_string_literal: true

module OuterIndex
  def index
    OuterIndexJob.perform_later
    super
  end
end
