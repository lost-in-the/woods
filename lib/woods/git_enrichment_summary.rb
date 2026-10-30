# frozen_string_literal: true

module Woods
  # The bounded, machine-readable answer to "can I trust the Git facts in this
  # index?", published in each generation's manifest as `git_enrichment`.
  #
  # Structural readiness says nothing about history: a run that cannot reach
  # Git still publishes a complete structural index, and units an incremental
  # run does not re-extract keep the facts an earlier capture gave them. This
  # summary says which of those two worlds a generation is in.
  #
  # Counting is by typed unit identity, one count per (identifier, type) node
  # of the dependency graph, so an identifier shared by two unit types counts
  # twice. A unit assembled from several source files counts once and has
  # facts when at least one of its sources has history.
  #
  # State:
  # - `available`: Git worked for this run and every eligible unit has facts.
  # - `degraded`: some eligible units have facts and some do not. Either Git
  #   failed for this run and earlier facts were retained, or Git works and a
  #   retained unit never had facts. A full extraction repairs both.
  # - `unavailable`: no eligible unit has facts. Includes a source archive
  #   with no Git directory, which remains a supported way to publish.
  # - `unknown`: the manifest predates the summary. Never healthy, never zero.
  #
  # A unit with a successfully observed zero commits in the history window has
  # facts. Only an absent fact is a failure.
  module GitEnrichmentSummary
    VERSION = 1

    # Units whose history belongs to someone else.
    DEPENDENCY_TYPES = %i[rails_source gem_source].freeze

    MISSING_FACTS = 'units_missing_facts'
    SUMMARY_MISSING = 'summary_missing'
    VERSION_UNSUPPORTED = 'summary_version_unsupported'

    module_function

    # An existing file inside the application, outside vendored code. The one
    # rule both per-unit enrichment and this coverage count apply.
    #
    # @param path [String] absolute path
    # @param root [String] application root with a trailing slash
    # @return [Boolean]
    def enrichable_path?(path, root)
      return false unless path&.start_with?(root)
      return false if path.include?('/vendor/') || path.include?('/node_modules/')

      File.exist?(path)
    end

    # @param graph [DependencyGraph] the final graph of the publication
    # @param root [String, Pathname] application root
    # @param availability [Hash] `{available: Boolean, reason: String, nil}`
    #   for this run's Git access; history that could not be read counts as
    #   unavailable
    # @param refreshed [Set<Array(String, String)>, :all] (identifier, type)
    #   pairs given facts in this publication; `:all` for a full extraction
    # @param head_sha [String, nil] HEAD this run read, nil without Git
    # @return [Hash] string-keyed, JSON-ready
    def build(graph:, root:, availability:, refreshed:, head_sha:)
      tally = tally_nodes(graph, "#{root}/", refreshed)
      state, reason = classify(availability, tally)

      {
        'version' => VERSION,
        'state' => state,
        'reason' => reason,
        'head_sha' => head_sha,
        'coverage' => coverage(tally),
        'capture' => { 'refreshed' => tally[:refreshed], 'retained' => tally[:with_facts] - tally[:refreshed] }
      }
    end

    # @param manifest [Hash, nil] a parsed manifest
    # @return [Hash] the published summary, or `unknown` when there is none
    def from_manifest(manifest)
      summary = manifest.is_a?(Hash) ? manifest['git_enrichment'] : nil
      return { 'state' => 'unknown', 'reason' => SUMMARY_MISSING } unless summary.is_a?(Hash)
      return { 'state' => 'unknown', 'reason' => VERSION_UNSUPPORTED } unless summary['version'] == VERSION

      summary
    end

    # One line for a task summary.
    #
    # @param summary [Hash] a {.build} or {.from_manifest} result
    # @return [String]
    def line(summary)
      state = summary['state']
      reason = summary['reason']
      return "Git enrichment: unknown (#{reason})" if state == 'unknown'

      coverage = summary.fetch('coverage')
      capture = summary.fetch('capture')
      label = reason ? "#{state}, #{reason}" : state
      "Git enrichment: #{label} (#{coverage['with_facts']} of #{coverage['eligible_units']} eligible units " \
        "with facts; #{capture['refreshed']} refreshed, #{capture['retained']} retained)"
    end

    def tally_nodes(graph, root, refreshed)
      tally = { eligible: 0, with_facts: 0, refreshed: 0, fileless: 0, dependency_owned: 0, source_missing: 0 }
      graph.each_node do |identifier, node|
        exclusion = exclusion_for(node, root)
        next tally[exclusion] += 1 if exclusion

        tally[:eligible] += 1
        next unless facts?(node)

        tally[:with_facts] += 1
        tally[:refreshed] += 1 if refreshed == :all || refreshed.include?([identifier, node[:type].to_s])
      end
      tally
    end

    def exclusion_for(node, root)
      return :dependency_owned if DEPENDENCY_TYPES.include?(node[:type])

      paths = source_paths_of(node, root)
      return :fileless if paths.empty?
      return nil if paths.any? { |path| enrichable_path?(path, root) }

      paths.none? { |path| application_owned?(path, root) } ? :dependency_owned : :source_missing
    end

    def source_paths_of(node, root)
      paths = Array(node[:source_paths]).empty? ? Array(node[:file_path]) : node[:source_paths]
      paths.map(&:to_s).reject(&:empty?).map { |path| File.expand_path(path, root) }
    end

    def application_owned?(path, root)
      path.start_with?(root) && !path.include?('/vendor/') && !path.include?('/node_modules/')
    end

    def facts?(node)
      !node[:commit_count].nil? || node[:git_sources].to_i.positive?
    end

    def classify(availability, tally)
      missing = tally[:eligible] - tally[:with_facts]
      if availability[:available]
        missing.positive? ? ['degraded', MISSING_FACTS] : ['available', nil]
      else
        [tally[:with_facts].positive? ? 'degraded' : 'unavailable', availability[:reason]]
      end
    end

    def coverage(tally)
      {
        'eligible_units' => tally[:eligible],
        'with_facts' => tally[:with_facts],
        'history_unavailable' => tally[:eligible] - tally[:with_facts],
        'excluded' => tally.slice(:fileless, :dependency_owned, :source_missing).transform_keys(&:to_s)
      }
    end

    private_class_method :tally_nodes, :exclusion_for, :source_paths_of,
                         :application_owned?, :facts?, :classify, :coverage
  end
end
