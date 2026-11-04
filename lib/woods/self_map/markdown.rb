# frozen_string_literal: true

require 'uri'

module Woods
  module SelfMap
    # Small deterministic renderers over recorded facts; no inferred prose policy.
    module Markdown
      module_function

      def escape(value)
        value.to_s.gsub(/[\\`*_\[\]|<>]/) { |char| "\\#{char}" }
      end

      def link(root, path)
        target = URI::DEFAULT_PARSER.escape(File.join(root.to_s, path), %r{[^a-zA-Z0-9\-._~/:]})
        "[#{escape(path)}](#{target})"
      end

      def impact(report, root)
        lines = ['# Woods static change impact', '',
                 'Recorded references and labelled owner candidates; not exhaustive call or test coverage.', '',
                 "Validation policy: #{link(root, 'CONTRIBUTING.md')}.",
                 'Suggested specs do not replace required checks.', '',
                 "Baseline: #{report.dig('coverage', 'baseline')}.", '', '## Suggested specs', '',
                 *report['suggested_specs'].map { |path| "- #{link(root, path)}" }]
        report['endpoints'].each { |endpoint| lines.concat(endpoint_lines(endpoint, root)) }
        lines.push('', 'Complete witness paths and coverage details: [impact.json](impact.json).', '').join("\n")
      end

      def affected_line(item, root)
        inferred = item['paths'].any? { |path| path['edges'].any? { |edge| edge['via'] == 'owner_expansion' } }
        "- #{escape(item['identifier'])} — #{link(root, item['file_path'])} " \
          "[#{inferred ? 'owner candidate' : 'recorded reference'}]"
      end

      def endpoint_lines(endpoint, root)
        ["\n## #{endpoint['side']} generation #{endpoint.dig('provenance', 'generation')}", '',
         "Traversal: #{endpoint['traversal']}; parse coverage: #{endpoint['parse_coverage']}.",
         "Unmapped inputs: #{endpoint['unmapped_paths'].map { |path| escape(path) }.join(', ')}.",
         "Parse failures: #{endpoint['parse_failures'].size}; " \
         "budget/identity notices: #{endpoint['unknowns'].size}.", '',
         *endpoint['affected'].first(20).map do |item|
           affected_line(item, root)
         end, '', 'Affected samples are bounded to 20; the JSON retains all results within traversal budgets.']
      end
    end
  end
end
