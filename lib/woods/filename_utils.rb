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
    # A SHA256 digest (the same disambiguation {#collision_safe_filename}
    # already uses) is appended whenever either segment's transform was
    # lossy — e.g. `bar.baz` and `bar_baz` both {.safe_segment} to `bar_baz`,
    # so writing them under one name means the second write clobbers the
    # first and `flow_index.json` points both entries at that one file. The
    # ordinary `::` → `__` namespace transform does NOT by itself count as
    # lossy ({.lossy_segment?} looks past it) — it is the one substitution
    # every identifier-to-filename convention in this file already makes, so
    # a namespaced controller keeps its plain name.
    #
    # @param controller_id [String] e.g. "Admin::UsersController"
    # @param action [String] e.g. "index"
    # @return [String] e.g. "Admin__UsersController_index.json"
    def self.flow_filename(controller_id, action)
      base = "#{safe_segment(controller_id)}_#{safe_segment(action)}"
      return "#{base}.json" unless lossy_segment?(controller_id) || lossy_segment?(action)

      digest = Digest::SHA256.hexdigest("#{controller_id}##{action}")[0, 8]
      "#{base}_#{digest}.json"
    end

    # Whether {.safe_segment} discarded information for +value+ beyond the
    # `::` → `__` namespace transform — i.e. whether some OTHER character
    # got folded to `_`. That residual loss is what makes two different
    # inputs land on the same segment (`bar.baz` and `bar_baz` both become
    # `bar_baz`); the namespace transform alone does not, since it is
    # applied uniformly and every caller already expects it.
    #
    # @param value [String]
    # @return [Boolean]
    def self.lossy_segment?(value)
      namespaced = value.to_s.gsub('::', '__')
      namespaced.gsub(/[^a-zA-Z0-9_-]/, '_') != namespaced
    end
    private_class_method :lossy_segment?

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
