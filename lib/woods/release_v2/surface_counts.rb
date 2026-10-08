# frozen_string_literal: true

require_relative 'surface_inventory'

module Woods
  module ReleaseV2
    # Rewrites the surface counts quoted in public documentation from code.
    #
    # The inverse of {SurfaceInventory.verify!}: the same claim patterns over
    # the same documents, with each quoted number replaced by the count the
    # code derives. Nothing here is a literal; run `script/sync-surface-counts`
    # after adding an extractor, a unit type or an MCP tool instead of editing
    # the numbers by hand.
    module SurfaceCounts
      ROOT = SurfaceInventory::ROOT

      class << self
        # @return [Array<Pathname>] the documents whose claims are verified
        def targets
          SurfaceInventory.send(:current_public_documentation_paths)
        end

        # @return [Hash{String => Integer}] the code-derived counts, by surface
        def counts
          SurfaceInventory.inventory.fetch('counts')
        end

        # @param source [String] document text
        # @param counts [Hash{String => Integer}] see {.counts}
        # @return [String] the text with every surface claim set to its code-derived count
        def rewrite(source, counts = self.counts)
          SurfaceInventory::DOCUMENTATION_SURFACE_CLAIM_PATTERNS.reduce(source) do |text, rule|
            count = counts.fetch(rule.fetch(:surface)).to_s
            text.gsub(rule.fetch(:pattern)) do
              match = Regexp.last_match
              from = match.begin(:count) - match.begin(0)
              to = match.end(:count) - match.begin(0)
              "#{match[0][0...from]}#{count}#{match[0][to..]}"
            end
          end
        end

        # @return [Array<String>] root-relative paths whose claims disagree with code
        def drift
          current = counts
          targets.filter_map do |path|
            source = SurfaceInventory.read_utf8(path)
            path.relative_path_from(ROOT).to_s unless rewrite(source, current) == source
          end
        end

        # Rewrite every drifted document in place.
        #
        # @return [Array<String>] root-relative paths that changed
        def write!
          drift.each do |relative|
            path = ROOT.join(relative)
            path.write(rewrite(SurfaceInventory.read_utf8(path)))
          end
        end
      end
    end
  end
end
