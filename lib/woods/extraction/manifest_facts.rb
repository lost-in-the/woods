# frozen_string_literal: true

module Woods
  module Extraction
    # Ordered manifest data composed from facts already acquired by one run.
    #
    # This internal projection does not acquire runtime or filesystem facts.
    # Full and incremental callers select their authoritative counts and
    # configuration fingerprint before invoking it.
    class ManifestFacts
      # Build the existing manifest shape without normalizing supplied facts.
      #
      # @param counts [Hash{Symbol => Integer}] ordered extractor counts
      # @param total_chunks [Integer] authoritative chunk count for the run
      # @param provenance [Hash] resolved :git_sha and :git_branch facts
      # @param extraction_config [Hash, nil] current full or baseline incremental digests
      # @param git_enrichment [Hash] computed Git coverage and capture account
      # @param git_filter_available [Boolean] whether Git filtering is available
      # @param extracted_at [String] timestamp acquired by the caller
      # @param woods_version [String] Woods version for this run
      # @param rails_version [String] Rails version for this run
      # @param ruby_version [String] Ruby version for this run
      # @param gemfile_lock_sha [String, nil] caller-acquired lockfile digest
      # @param schema_sha [String, nil] caller-acquired schema digest
      # @return [Hash] new manifest container with the existing field order
      # Explicit value inputs mirror the manifest instead of sharing a run context.
      # rubocop:disable-next Metrics/ParameterLists
      def self.build(counts:, total_chunks:, provenance:, extraction_config:, git_enrichment:,
                     git_filter_available:, extracted_at:, woods_version:, rails_version:, ruby_version:,
                     gemfile_lock_sha:, schema_sha:)
        manifest = {
          extracted_at: extracted_at,
          woods_version: woods_version,
          rails_version: rails_version,
          ruby_version: ruby_version,
          counts: counts,
          total_units: counts.values.sum,
          total_chunks: total_chunks,
          git_sha: provenance[:git_sha],
          git_branch: provenance[:git_branch],
          gemfile_lock_sha: gemfile_lock_sha,
          schema_sha: schema_sha
        }

        manifest[:extraction_config] = extraction_config if extraction_config
        manifest[:git_enrichment] = git_enrichment
        manifest[:metadata] = { git_filter: 'unavailable' } unless git_filter_available
        manifest
      end
    end
  end
end
