# frozen_string_literal: true

require 'woods'

module Woods
  module Obsidian
    # Raised for recoverable Obsidian export failures (e.g. a missing extraction
    # output dir). Inherits Woods::Error so callers can rescue the gem's hierarchy.
    class ExportError < Woods::Error; end

    # Raised when a computed write target resolves outside the vault root.
    # The fail-closed counterpart to the dir_for/NameMapper sanitizers: those
    # are expected to prevent this from ever firing, but a future regression
    # in either one must refuse the write, not silently escape the vault.
    class PathTraversalError < ExportError; end
  end
end
