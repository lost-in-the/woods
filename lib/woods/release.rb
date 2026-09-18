# frozen_string_literal: true

module Woods
  # Maintainer-only release machinery, deliberately not packaged with the gem.
  # These files back `release:prepare` and `release:reopen`, which only ever run
  # from a source checkout of this repository.
  module Release
    # Every refusal the release flow raises. `lib/tasks/release.rake` rescues
    # this one class and turns it into a clean abort.
    class Error < StandardError; end
  end
end
