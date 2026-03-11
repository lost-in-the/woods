# frozen_string_literal: true

require 'json'
require 'time'

module CodebaseIndex
  module Operator
    # Reports pipeline status by reading extraction output metadata.
    #
    # @example
    #   reporter = StatusReporter.new(output_dir: 'tmp/codebase_index')
    #   status = reporter.report
    #   status[:status]           # => :ok
    #   status[:staleness_seconds] # => 3600
    #
    class StatusReporter
      STALE_THRESHOLD = 86_400 # 24 hours

      # @param output_dir [String] Path to extraction output directory
      def initialize(output_dir:)
        @output_dir = output_dir
      end

      # Generate a pipeline status report.
      #
      # @return [Hash] Status report with :status, :extracted_at, :total_units, :counts, :staleness_seconds
      def report
        manifest = read_manifest
        return not_extracted_report if manifest.nil?

        staleness = compute_staleness(manifest['extracted_at'])

        {
          status: staleness < STALE_THRESHOLD ? :ok : :stale,
          extracted_at: manifest['extracted_at'],
          total_units: manifest['total_units'] || 0,
          counts: manifest['counts'] || {},
          git_sha: manifest['git_sha'],
          git_branch: manifest['git_branch'],
          staleness_seconds: staleness
        }
      end

      private

      # @return [Hash, nil]
      def read_manifest
        path = File.join(@output_dir, 'manifest.json')
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      # @return [Hash]
      def not_extracted_report
        {
          status: :not_extracted,
          extracted_at: nil,
          total_units: 0,
          counts: {},
          git_sha: nil,
          git_branch: nil,
          staleness_seconds: nil
        }
      end

      # @param extracted_at [String, nil] ISO8601 timestamp
      # @return [Numeric]
      def compute_staleness(extracted_at)
        return Float::INFINITY if extracted_at.nil?

        Time.now - Time.parse(extracted_at)
      rescue ArgumentError
        Float::INFINITY
      end
    end
  end
end
