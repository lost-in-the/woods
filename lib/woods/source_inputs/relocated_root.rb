# frozen_string_literal: true

require 'woods/source_path_encoding'

module Woods
  module SourceInputs
    # The source root a check reads when the root a generation recorded is
    # not a directory here: the same checkout served under another path.
    #
    # The caller supplies the candidate (the MCP reader passes the
    # application that owns the served index directory). It is used only
    # when the recorded root is unreachable, and is reported as
    # `re_resolved`. It stands only on an identity tie: when the generation
    # captured `config/application.rb`, that file must still have its
    # captured bytes (it names the application's module); otherwise at least
    # one captured file must. Without the tie the result is `unknown` with
    # `source_root_unavailable`. The tie is a heuristic: it rejects a tree
    # whose application file differs, not every unrelated tree.
    class RelocatedRoot
      REJECTED = 'no_identity_match'

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

      # A scan cut short keeps its reason, so a quick check that ran out of
      # time still recommends a deep one.
      #
      # @param result [Hash] the verifier result
      # @return [Hash]
      def checked(result)
        coverage = result['coverage']
        return result unless @path && coverage && !tied?(coverage)

        reasons = (result.fetch('verification_reasons') + ['source_root_unavailable']).uniq
        result.slice('mode', 'generation', 'checked_at', 'recorded_root', 'checked_root', 'root_source', 'coverage')
              .merge('state' => 'unknown', 'reasons' => ['source_root_unavailable'], 'complete' => false,
                     'root_rejected' => REJECTED, 'verification_reasons' => reasons)
      end

      private

      def tied?(coverage)
        return coverage['application_verified'] if coverage.key?('application_verified')

        coverage.fetch('verified_files').positive?
      end
    end
  end
end
