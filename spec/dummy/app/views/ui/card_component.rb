# frozen_string_literal: true

module Ui
  # A component living beside its templates, under an autoloaded but not
  # eager-loaded subtree of app/views. Discovery keyed on
  # `component_base.descendants` never saw this class, because nothing had
  # asked the autoloader for it (B-184).
  class CardComponent < ApplicationComponent
    def initialize(title:, subtitle: nil)
      @title = title
      @subtitle = subtitle
      super()
    end

    def call
      "#{@title} #{@subtitle}"
    end
  end
end
