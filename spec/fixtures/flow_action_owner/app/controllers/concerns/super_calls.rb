# frozen_string_literal: true

# Each body calls super where a flow cannot place it by line alone.
module SuperCalls
  def twice
    super
    BetweenJob.perform_later
    super
  end

  # rubocop:disable-next Style/SingleLineMethods, Style/Semicolon
  def compact; super; AfterCompactJob.perform_later; end

  def gated
    if gate_open? # rubocop:disable Style/GuardClause
      super
      AfterGatedJob.perform_later
    end
  end

  def locked
    ActiveRecord::Base.transaction do
      super
      AfterLockedJob.perform_later
    end
  end
end
