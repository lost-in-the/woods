# frozen_string_literal: true

module IncludedShow
  def show
    IncludedShowJob.perform_later
  end
end
