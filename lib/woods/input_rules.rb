# frozen_string_literal: true

require 'woods/reload_policy'
require 'woods/path_dispatcher'

module Woods
  # Shared fresh-process action contract. Loading this class does not boot Rails.
  # Extractor constants are needed only when deriving the dispatcher projection.
  class InputRules
    def action(path, operation: 'update')
      return :full if ReloadPolicy.new.classify(path) == :restart
      return :ignore unless PathDispatcher.new.relevant?(path)

      # A removed runtime class may no longer be discoverable in a fresh boot.
      # Full extraction also handles the old side of a rename conservatively.
      %w[delete move].include?(operation) ? :full : :incremental
    end
  end
end
