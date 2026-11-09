# frozen_string_literal: true

# Process-local fault injection: leave the real before publication untouched
# while the real fresh task process observes the after source. Never loaded in
# the positive run and never changes product code or a user's application.
require 'rake'

module WoodsVerificationSkipIncremental
  def invoke(*args)
    return if name == 'woods:incremental'

    super
  end
end
Rake::Task.prepend(WoodsVerificationSkipIncremental)
