# frozen_string_literal: true

require 'digest'

module Woods
  # Shared filename helpers for converting unit identifiers to safe filenames.
  #
  # Used by Extractor (writing) and IndexValidator (reading) to ensure
  # filename generation is consistent across both sides.
  module FilenameUtils
    # Normalize a single identifier segment for use in a filename: replace
    # `::` with `__` and every other non-`[a-zA-Z0-9_-]` character with `_`.
    # This is the one character transform shared by {#safe_filename},
    # {#collision_safe_filename}, and the precomputed-flow reader/writer
    # (via {.flow_filename}) so the sides of each filename contract cannot
    # drift. Also usable as a module method (`FilenameUtils.safe_segment`)
    # for callers that don't mix the module in.
    #
    # @param identifier [String]
    # @return [String]
    def self.safe_segment(identifier)
      identifier.to_s.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    end

    # Filename for a precomputed request-flow document, combining the
    # controller identifier and action name — each normalized via
    # {.safe_segment}. Used by both {Woods::FlowPrecomputer} (writing) and the
    # MCP server's `trace_flow` (reading) so a name containing an
    # out-of-charset character is written and looked up under the SAME file
    # (the writer previously left the action raw while the reader allow-listed
    # it, so such flows were written under one name and never found).
    #
    # @param controller_id [String] e.g. "Admin::UsersController"
    # @param action [String] e.g. "index"
    # @return [String] e.g. "Admin__UsersController_index.json"
    def self.flow_filename(controller_id, action)
      "#{safe_segment(controller_id)}_#{safe_segment(action)}.json"
    end

    # Convert an identifier to a safe filename (legacy format).
    #
    # @param identifier [String] The unit identifier (e.g., "Admin::UsersController")
    # @return [String] A filesystem-safe filename (e.g., "Admin__UsersController.json")
    def safe_filename(identifier)
      "#{FilenameUtils.safe_segment(identifier)}.json"
    end

    # Convert an identifier to a collision-safe filename (current format).
    #
    # Appends a short SHA256 digest to disambiguate identifiers that normalize
    # to the same safe_filename.
    #
    # @param identifier [String] The unit identifier
    # @return [String] Collision-safe filename (e.g., "Admin__UsersController_a1b2c3d4.json")
    def collision_safe_filename(identifier)
      base = FilenameUtils.safe_segment(identifier)
      digest = Digest::SHA256.hexdigest(identifier)[0, 8]
      "#{base}_#{digest}.json"
    end
  end
end
