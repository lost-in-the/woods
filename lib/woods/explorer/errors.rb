# frozen_string_literal: true

require 'woods'

module Woods
  module Explorer
    # Raised when the explorer export cannot proceed (missing index, foreign
    # output directory, unwritable target). Mirrors Woods::Obsidian::ExportError.
    class ExportError < Woods::Error; end
  end
end
