# frozen_string_literal: true

# What an error shows wherever it is reported: its message, the class and
# message of every error in its cause chain (the chain rake prints as
# "Caused by:" and error reporters walk), and +full_message+, which an
# uncaught error prints.
module CauseChain
  # @param error [Exception]
  # @return [String]
  def cause_chain_text(error)
    chain = []
    current = error
    while current && !chain.include?(current)
      chain << current
      current = current.cause
    end
    [*chain.map { |link| "#{link.class}: #{link.message}" }, error.full_message(highlight: false)].join("\n")
  end
end

RSpec.configure { |config| config.include CauseChain }
