# frozen_string_literal: true

# Resilience facts from the class (W-4, woods#754): an inherited retry_on, its
# own discard_on, rescue_from and around_perform, and a comment that names
# retry_on without declaring it.
#
# retry_on ArgumentError would be a declaration only if it were code.
class ResilientJob < ApplicationJob
  discard_on KeyError
  rescue_from IndexError, with: :report
  around_perform :with_lock

  def perform(id) = id

  private

  def report(error) = error

  def with_lock = yield
end
