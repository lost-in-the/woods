# frozen_string_literal: true

# Guards the one assumption every `:booted_app` spec makes and none of them
# could previously check.
#
# `Rails::Application` is a singleton: the first `initialize!` in a process
# wins, permanently. So all four booted specs share one `WoodsDummyApplication`
# constant behind an `unless defined?` guard, and each points it at a *different*
# root — `spec/dummy` for the extraction spec, a private tmpdir for the other
# three.
#
# Run one file per process and that is fine. Run two in one process —
# `rspec spec/integration/`, which CLAUDE.md itself suggests — and whichever
# boots first silently decides the root for all of them. Under
# `config.order = :random` that is a coin flip, and the failure is worse than a
# crash: a harness that extracts a tree it never mutates compares two identical
# indexes and passes while testing nothing at all.
#
# CI runs each file as its own step, so it never sees this. A spec should not
# depend on how it happens to be invoked.
module BootedAppRoot
  module_function

  # @param expected [String] the root this spec set up and mutates
  # @raise [RuntimeError] when another booted spec won the race
  # @return [void]
  def assert!(expected)
    actual = Rails.application.root.to_s
    return if actual == expected.to_s

    raise <<~MESSAGE
      Booted-app root mismatch.

        Rails.application.root: #{actual}
        this spec set up:       #{expected}

      Another :booted_app spec initialized WoodsDummyApplication first — Rails
      applications are singletons, so its root won. Run this file in its own
      process (see the per-file steps in .github/workflows/ci.yml) rather than
      loading spec/integration/ as a whole.
    MESSAGE
  end
end
