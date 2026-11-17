# frozen_string_literal: true

module InnerIndex
  def index
    InnerIndexJob.perform_later
    super
  end
end
