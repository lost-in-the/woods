# frozen_string_literal: true

require 'woods/source_path_encoding'

module Woods
  module SourceInputs
    # The source root a check reads when the root a generation recorded is
    # not a directory here: the same checkout served under another path.
    #
    # The caller supplies the candidate (the MCP reader passes the
    # application that owns the served index directory). It is used only
    # when the recorded root is unreachable, it is reported as
    # `re_resolved`, and it counts only when at least one captured file in it
    # still has its captured bytes. Otherwise the result is
    # `source_root_unavailable`, never drift against an unrelated tree.
    class RelocatedRoot
      REJECTED = 'no_captured_file_matches'

      # @param candidate [String, nil]
      # @param manifest [Manifest]
      def initialize(candidate, manifest)
        recorded = SourcePathEncoding.expand(manifest.data.fetch('root'))
        @path = SourcePathEncoding.expand(candidate) if candidate && !File.directory?(recorded)
      end

      # @return [String, nil] the root to check, or nil to keep the recorded one
      attr_reader :path

      # @return [String, nil]
      def source
        're_resolved' if @path
      end

      # A guess from the index location stands only on byte evidence: a scan
      # that verified no captured file has nothing tying that tree to this
      # index. A scan cut short keeps its reason, so a quick check that ran
      # out of time still recommends a deep one.
      #
      # @param result [Hash] the verifier result
      # @return [Hash]
      def checked(result)
        return result unless @path && result.dig('coverage', 'verified_files')&.zero?

        reasons = (result.fetch('verification_reasons') + ['source_root_unavailable']).uniq
        result.slice('mode', 'generation', 'checked_at', 'recorded_root', 'checked_root', 'root_source')
              .merge('state' => 'unknown', 'reasons' => ['source_root_unavailable'], 'complete' => false,
                     'root_rejected' => REJECTED, 'verification_reasons' => reasons)
      end
    end
  end
end
