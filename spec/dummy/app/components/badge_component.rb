# frozen_string_literal: true

# A component in an eager-loaded directory, so discovery finds it either way.
# It is the control for the app/views one.
class BadgeComponent < ApplicationComponent
  def initialize(label:)
    @label = label
    super()
  end

  def call
    @label.to_s
  end
end
