# frozen_string_literal: true

require 'woods'

module Woods
  module Obsidian
    # Raised for recoverable Obsidian export failures (e.g. a missing extraction
    # output dir). Inherits Woods::Error so callers can rescue the gem's hierarchy.
    class ExportError < Woods::Error; end
  end
end
