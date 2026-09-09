# frozen_string_literal: true

require 'json'
require 'fileutils'

module Woods
  module Evaluation
    # Serializes an {AblationRunner::Report} to JSON and renders the terminal
    # summary for `woods:evaluate:ablation` (#280).
    class AblationReportWriter
      # @param report [AblationRunner::Report]
      def initialize(report)
        @report = report
      end

      # @param path [String]
      # @return [void]
      def write(path)
        FileUtils.mkdir_p(File.dirname(path))
        results = @report.results.map { |result| result.to_h.merge(provenance: result.provenance.to_h) }
        File.write(path, JSON.pretty_generate('summary' => @report.summary, 'results' => results))
      end

      # @return [String] a human-readable summary, explicit that this is a
      #   paired-run harness rather than a causal-evidence report
      def summary_text
        lines = ['', 'Ablation complete! This is a harness for paired runs, not causal evidence.', '=' * 50]
        %i[on off delta].each { |condition| lines.concat(condition_lines(condition)) }
        lines << ('=' * 50)
        lines.join("\n")
      end

      private

      def condition_lines(condition)
        section = @report.summary[condition]
        return [] unless section

        ["  #{condition}:"] + section.map { |key, value| "    #{key.to_s.ljust(18)}: #{value.nil? ? 'n/a' : value}" }
      end
    end
  end
end
