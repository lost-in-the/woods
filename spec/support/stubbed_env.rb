# frozen_string_literal: true

require 'delegate'

# Replace ENV for one example without handing Ruby a plain Hash in its place.
#
# Ruby 3.0 builds a child's environment from whatever `ENV.to_hash` returns
# and hides that object while it spawns. A Hash returns itself, so a spawn
# with an environment hash (every Woods git command passes one) strips the
# stubbed Hash of its class, and the next call on ENV segfaults. This
# stand-in answers `to_hash` with a copy. Ruby 3.1 and later copy anyway.
module StubbedEnv
  # Hash-backed ENV stand-in whose `to_hash` never returns the backing Hash.
  class Table < SimpleDelegator
    # @return [Hash] a copy, safe for the interpreter to hide
    def to_hash
      __getobj__.dup
    end
  end

  # @param values [Hash{String => String}] the whole environment for this example
  def replace_env(values)
    stub_const('ENV', Table.new(values.to_h))
  end
end

RSpec.configure { |config| config.include StubbedEnv }
