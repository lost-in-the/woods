# frozen_string_literal: true

# The two bodies of each action whose definitions are exclusive branches of one line.
module Flip
  class A < ApplicationJob
    def perform; end
  end

  class B < ApplicationJob
    def perform; end
  end
end
