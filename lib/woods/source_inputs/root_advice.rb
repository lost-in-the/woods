# frozen_string_literal: true

module Woods
  module SourceInputs
    # Advice for a check whose recorded source root is not a directory where
    # the check runs (an index extracted in a container and read on the host)
    # when no other root stood in for it. Another extraction records the same
    # root, so this replaces `fresh_capture` for that result.
    module RootAdvice
      # The recommendation value.
      RECOMMENDATION = 'map_source_root'

      # What the recommendation asks for, returned as `root_advice`.
      TEXT = 'The source root this index recorded is not a directory where this check runs, and no matching ' \
             'checkout was found from the index location. Run the check where the recorded root exists (for an ' \
             'index extracted in a container, launch the Index Server through that container), or set ' \
             'WOODS_SOURCE_ROOT in the MCP server environment to the path of the same checkout on this machine. ' \
             'Extracting again records the same root and does not change this result.'

      module_function

      # Whether the recorded root is absent here and nothing replaced it: the
      # checked root is not a directory, or a re-resolved one failed its
      # identity tie. A root that exists but could not be scanned is a scan
      # problem, not this.
      #
      # @param result [Hash] a verifier result
      # @return [Boolean]
      def applies?(result)
        return false unless result.fetch('reasons').include?('source_root_unavailable')

        result.key?('root_rejected') || !File.directory?(result.fetch('checked_root'))
      end

      # @param result [Hash] a verifier result
      # @return [Hash] the result, with `root_advice` when it applies
      def annotate(result)
        applies?(result) ? result.merge('root_advice' => TEXT) : result
      end

      # A capture cannot be judged against a root nobody could read, so
      # `fresh_capture` is never part of this advice.
      #
      # @param reader_reasons [Array<String>] the scan's remaining reasons
      # @return [Array<String>]
      def recommendations(reader_reasons)
        scan = reader_reasons - ['source_root_unavailable']
        scan.empty? ? [RECOMMENDATION] : ['inspect_source_scan', RECOMMENDATION]
      end
    end
  end
end
