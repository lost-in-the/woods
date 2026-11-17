# frozen_string_literal: true

module ReplacedCreate
  def create
    ReplacedCreateJob.perform_later
  end
end
