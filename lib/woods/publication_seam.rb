# frozen_string_literal: true

module Woods
  # Named points on the publish path where a test can stop a writer.
  #
  # The writer-fencing contract is about order: what an obsolete writer does
  # when it resumes after another writer took its lock over and published. A
  # test of that needs to stop the writer at an exact point and let it go
  # again, so the publish path calls {.reach} at each point and a test
  # installs a hook. With no hook installed (always, outside tests) {.reach}
  # does nothing.
  #
  # Points, in the order a publishing run reaches them:
  #
  # * `:staged` — the private stage is seeded; the run is about to write.
  # * `:before_promotion` — the stage is complete and flushed, outside the
  #   writer fence.
  # * `:promoted` — inside the fence: the stage is now `gen-<n>`, the marker
  #   still names `n - 1`.
  # * `:marker_published` — inside the fence: the marker names `n`; retention
  #   has not run.
  # * `:published` — the fence is released; the run is done publishing.
  #
  # And one for `woods:clean`:
  #
  # * `:swept_entry` — one index entry has been removed, outside the fence.
  module PublicationSeam
    POINTS = %i[staged before_promotion promoted marker_published published swept_entry].freeze

    @hook = nil

    class << self
      # @return [#call, nil] called with the point name and the output directory
      attr_accessor :hook

      # @param point [Symbol] one of {POINTS}
      # @param output_dir [Pathname, String]
      # @return [void]
      def reach(point, output_dir)
        hook&.call(point, output_dir)
      end
    end
  end
end
