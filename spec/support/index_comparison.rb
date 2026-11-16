# frozen_string_literal: true

require 'json'
require 'woods/atomic_file'
require 'woods/generation'

# Compares two Woods index directories and reports every way they differ.
#
# The oracle behind the incremental differential harness (#164): an index
# maintained by `Extractor#extract_changed` has to be indistinguishable from a
# cold `extract_all` of the same tree. This module owns "indistinguishable"
# so the harness spec can stay about *operations*, and so the definition is
# stated once, in one place, with its exclusions justified.
#
# Every exclusion is a row of {MASKS}: what it hides, how wide it is, and why
# a full and an incremental run may legitimately differ there. Nothing else is
# forgiven. Everything outside the table — unit sets, unit content (including
# the order of `dependents`, which both paths serialize sorted), `_index.json`,
# graph nodes, edges, reverse edges, file map, type index, stats, PageRank
# scores, manifest counts, the skipped-files report, the commit table,
# `graph_analysis.json` (including `graph_sha`, the digest of the graph file's
# bytes), flow artifacts, and SUMMARY.md's totals against the manifest of the
# same index — must match exactly.
#
# A non-empty result ends with a line naming the masks in effect, and the full
# report (every difference, every mask with its reason) goes to stderr, so a
# red run shows what was *not* compared. `WOODS_DIFF_MASKS=1` prints the masks
# on success too. `spec/support/index_comparison_self_check.rb` proves on a
# real index that each mask is exactly as wide as declared.
#
# Flow artifacts (`flows/flow_index.json` and every document it lives beside)
# are compared too, once the run enables flow precomputation: flow documents
# are excluded from the unit set (they are not units) and compared in their
# own snapshot instead (M3).
module IndexComparison # rubocop:disable Metrics/ModuleLength
  # One declared exclusion from the comparison.
  #
  # Widths:
  # - `:key` drops one key (at `path`) from each document of the artifact.
  # - `:order` compares the array(s) at `path` as sorted lists.
  # - `:precision` compares the numbers at `path` rounded to `digits`.
  # - `:section` drops a whole top-level section of a compared document.
  # - `:artifact` leaves a whole file, or all of it but one checked span, uncompared.
  # - `:representation` covers byte layout: documents are compared as parsed values.
  #
  # A `:section` or `:artifact` mask, a key mask over {MAX_KEY_SHARE} of its
  # artifact's bytes, or one that empties a document, is *wide* and must say
  # so with its own `wide:` reason.
  class Mask
    WIDTHS = %i[key order precision section artifact representation].freeze

    attr_reader :name, :artifact, :path, :width, :reason, :wide, :digits

    # @param name [Symbol] unique name, used to select the mask
    # @param artifact [Symbol] a key of {IndexComparison::ARTIFACTS}
    # @param width [Symbol] one of {WIDTHS}
    # @param reason [String] why a full and an incremental run may differ here
    # @param path [Array<String>] keys from the document root to what is masked
    # @param wide [String, nil] why this mask may hide more than {MAX_KEY_SHARE}
    # @param default [Boolean] false for a mask only an example names explicitly
    # @param digits [Integer, nil] decimal places kept by a `:precision` mask
    def initialize(name:, artifact:, width:, reason:, path: [], wide: nil, default: true, digits: nil)
      @name = name
      @artifact = artifact
      @width = width
      @reason = reason
      @path = path.freeze
      @wide = wide
      @default = default
      @digits = digits
      freeze
    end

    # @return [Boolean] whether {IndexComparison.differences} applies it unasked
    def default?
      @default
    end

    # @return [Boolean] whether the mask is declared wide
    def wide?
      !@wide.nil?
    end

    # @return [String] artifact and path, for a failure report
    def target
      [IndexComparison::ARTIFACTS.fetch(artifact), *path].join(' ')
    end

    # @return [String] one report line
    def to_s
      "#{name} (#{width}: #{target}): #{reason}#{" Wide: #{wide}" if wide?}"
    end
  end

  # What each artifact symbol names inside a published payload.
  ARTIFACTS = {
    unit: '<type>/<unit>.json',
    type_index: '<type>/_index.json',
    dependency_graph: 'dependency_graph.json',
    manifest: 'manifest.json',
    skipped_files: 'skipped_files.json',
    commit_table: 'git_commits.json',
    graph_analysis: 'graph_analysis.json',
    flow: 'flows/*.json',
    summary: 'SUMMARY.md',
    source_inputs: 'source_inputs.json',
    source_references: 'source_references.json',
    outside_payload: '<output dir>/ outside the payload',
    json: 'every JSON artifact',
    impact_report: 'Woods::Impact::Report item'
  }.freeze

  # A key mask that removes more than this share of its artifact's bytes is wide.
  MAX_KEY_SHARE = 0.10

  # PageRank is iterative floating point, so the two runs can accumulate in
  # different orders and disagree in the last bits. Six decimal places is far
  # tighter than any real divergence — a score carried over from a graph that
  # has since changed differs in the first two or three — while leaving no room
  # for float noise to produce a spurious failure.
  PAGERANK_PRECISION = 6

  GRAPH_ORDER_REASON = 'Each entry is compared as a sorted list: the members are a set, filled in whatever ' \
                       'order each run registered nodes. The bytes as written are still compared through ' \
                       'graph_analysis.json graph_sha.'
  GRAPH_SECTION_WIDE = 'A whole section. Its bytes are still compared through graph_analysis.json graph_sha, ' \
                       'which digests the graph file as written.'

  MASKS = [
    Mask.new(name: :unit_extracted_at, artifact: :unit, width: :key, path: %w[extracted_at],
             reason: 'Wall-clock stamp of the write. A unit an incremental run correctly left alone keeps ' \
                     'its older stamp.'),
    Mask.new(name: :manifest_extracted_at, artifact: :manifest, width: :key, path: %w[extracted_at],
             reason: 'Wall-clock stamp of the publication.'),
    Mask.new(name: :manifest_extractor_timings, artifact: :manifest, width: :key, path: %w[extractor_timings],
             reason: 'Wall seconds per extractor family (LOS-130): an incremental run times only the families ' \
                     'it reached, and no two runs take the same time.',
             wide: 'About a fifth of the manifest: one number per extractor family. None of it is index content.'),
    Mask.new(name: :manifest_git_capture, artifact: :manifest, width: :key, path: %w[git_enrichment capture],
             reason: 'How many Git facts this publication refreshed and how many it retained. A full run ' \
                     'refreshes every fact; an incremental run retains the untouched ones. The state, reason, ' \
                     'HEAD and coverage beside it are compared.'),
    Mask.new(name: :analysis_generated_at, artifact: :graph_analysis, width: :key, path: %w[generated_at],
             reason: 'Wall-clock stamp of the analysis. graph_sha beside it is compared.'),
    Mask.new(name: :flow_generated_at, artifact: :flow, width: :key, path: %w[generated_at],
             reason: 'Wall-clock stamp at the top of each flow document (M3).'),
    Mask.new(name: :commit_table_since, artifact: :commit_table, width: :key, path: %w[since],
             reason: "The history window's first UTC day: two runs either side of midnight UTC differ there " \
                     'and nowhere else unless a commit sits on the boundary.'),
    Mask.new(name: :pagerank_precision, artifact: :dependency_graph, width: :precision, path: %w[pagerank],
             digits: PAGERANK_PRECISION,
             reason: "Iterative floating point, accumulated in each run's registration order. Scores are " \
                     'compared as values; only digits past the sixth decimal place are forgiven.'),
    Mask.new(name: :graph_edges_order, artifact: :dependency_graph, width: :order, path: %w[edges],
             reason: GRAPH_ORDER_REASON),
    Mask.new(name: :graph_reverse_order, artifact: :dependency_graph, width: :order, path: %w[reverse],
             reason: GRAPH_ORDER_REASON),
    Mask.new(name: :graph_file_map_order, artifact: :dependency_graph, width: :order, path: %w[file_map],
             reason: GRAPH_ORDER_REASON),
    Mask.new(name: :graph_type_index_order, artifact: :dependency_graph, width: :order, path: %w[type_index],
             reason: GRAPH_ORDER_REASON),
    Mask.new(name: :type_index_order, artifact: :type_index, width: :order,
             reason: 'Entries are compared sorted by identifier: the index lists units in the order each run ' \
                     'wrote them.'),
    Mask.new(name: :graph_reverse_via, artifact: :dependency_graph, width: :section, path: %w[reverse_via],
             reason: 'Not read here: it is derived from edges, which are compared.', wide: GRAPH_SECTION_WIDE),
    Mask.new(name: :graph_node_facts, artifact: :dependency_graph, width: :section, path: %w[node_facts],
             reason: 'Not read here: per-node facts derived from the units, which are compared.',
             wide: GRAPH_SECTION_WIDE),
    Mask.new(name: :summary_body, artifact: :summary, width: :artifact,
             reason: "Only the totals line is checked, against each index's own manifest (M4). The body " \
                     "carries a Generated: stamp, so the two runs' files never match byte for byte.",
             wide: 'Everything but one line of the file.'),
    Mask.new(name: :source_inputs, artifact: :source_inputs, width: :artifact,
             reason: 'Source provenance, not index content: identities are digests keyed by each output ' \
                     "directory's private key. A partial run also lists other scope paths than a full run, " \
                     'with or without a runtime_consumption uncertainty; docs/SOURCE_FRESHNESS.md describes ' \
                     'the runtime and table-family cases, not every one measured.',
             wide: 'The whole file. Its identities cannot be compared across output directories, and its ' \
                   'scope lists are not held equal to a full run.'),
    Mask.new(name: :source_references, artifact: :source_references, width: :artifact,
             reason: "The source-reference cache: each file's identity is a digest keyed by the output " \
                     "directory's private key. The edges it resolves are compared in the units and the graph.",
             wide: 'The whole file, though only files.*.identity differed between runs when measured.'),
    Mask.new(name: :outside_payload, artifact: :outside_payload, width: :artifact,
             reason: 'generation.json, locks, the source-input key and the snapshot store record publication ' \
                     'history and process state. The published payload they point at is what is compared.',
             wide: 'Every file outside the published payload directory.'),
    Mask.new(name: :json_representation, artifact: :json, width: :representation,
             reason: 'Documents are compared as parsed values: object key order, whitespace and number ' \
                     'spelling are not. graph_sha covers the bytes of the graph file.'),
    Mask.new(name: :impact_item_generation, artifact: :impact_report, width: :key, path: %w[generation],
             default: false,
             reason: 'The generation number an impact report item was read from: publication history, not ' \
                     'the content compared beside it.')
  ].freeze

  DEFAULT_MASKS = MASKS.select(&:default?).map(&:name).freeze

  module_function

  # @param name [Symbol]
  # @return [Mask]
  def mask_named(name)
    MASKS.find { |mask| mask.name == name } || raise(ArgumentError, "no mask named #{name.inspect}")
  end

  # Apply one named mask to a parsed document an example compares itself.
  #
  # @param name [Symbol] a `:key` mask of {MASKS}
  # @param document [Hash]
  # @return [Hash] a copy without the masked key
  # @raise [ArgumentError] for a mask of another width, or a document that is not a Hash
  def mask(name, document)
    selected = mask_named(name)
    raise ArgumentError, "#{name} is a #{selected.width} mask, not a key mask" unless selected.width == :key
    raise ArgumentError, "#{name} masks a Hash, not #{document.inspect[0, 80]}" unless document.is_a?(Hash)

    drop_path(document, selected.path)
  end

  # @param incremental_dir [String] index maintained by extract_changed
  # @param full_dir [String] index from a cold extract_all of the same tree
  # @param masks [Array<Symbol>] names from {MASKS}; an example may narrow or extend the default set
  # @return [Array<String>] human-readable differences; empty means equivalent
  def differences(incremental_dir, full_dir, masks: DEFAULT_MASKS)
    active = active_masks(masks)
    found = compare(incremental_dir, full_dir, masks: masks)
    warn(mask_report(active)) if found.empty? && ENV['WOODS_DIFF_MASKS'] == '1'
    return found if found.empty?

    warn("IndexComparison: #{incremental_dir} differs from #{full_dir}\n  #{found.join("\n  ")}\n" \
         "#{mask_report(active)}")
    found + ["not compared: #{active.map(&:name).join(', ')} (reasons on stderr and in IndexComparison::MASKS)"]
  end

  # {differences} without the report: the raw list, for a caller that expects some.
  #
  # @return [Array<String>]
  def compare(incremental_dir, full_dir, masks: DEFAULT_MASKS)
    active = active_masks(masks)
    nothing_compared(incremental_dir, full_dir) +
      unit_differences(incremental_dir, full_dir, active) +
      type_index_differences(incremental_dir, full_dir, active) +
      graph_differences(incremental_dir, full_dir, active) +
      manifest_differences(incremental_dir, full_dir, active) +
      skipped_files_differences(incremental_dir, full_dir) +
      commit_table_differences(incremental_dir, full_dir, active) +
      analysis_differences(incremental_dir, full_dir, active) +
      flow_differences(incremental_dir, full_dir, active) +
      summary_differences(incremental_dir) +
      summary_differences(full_dir)
  end

  # Resolve names to masks. A `:section`, `:artifact` or `:representation`
  # mask has no comparison behind it to fall back on, so it cannot be lifted.
  #
  # @return [Array<Mask>]
  def active_masks(names)
    missing = MASKS.select { |mask| mask.default? && UNLIFTABLE.include?(mask.width) }.map(&:name) - names
    raise ArgumentError, "no comparison exists for #{missing.join(', ')}: they cannot be lifted" if missing.any?

    names.map { |name| mask_named(name) }
  end

  UNLIFTABLE = %i[section artifact representation].freeze

  # @return [String] every mask in effect, with its reason
  def mask_report(active)
    "IndexComparison masks in effect (#{active.size}; not compared):\n  #{active.join("\n  ")}"
  end

  # Two directories with no manifest between them compare as "equal" only
  # because there was nothing to read. That is never a pass.
  def nothing_compared(incremental_dir, full_dir)
    return [] if read_json(incremental_dir, 'manifest.json') || read_json(full_dir, 'manifest.json')

    ["nothing compared: neither #{incremental_dir} nor #{full_dir} holds a published manifest.json"]
  end

  def unit_differences(incremental_dir, full_dir, active = default_masks)
    incremental = unit_snapshot(incremental_dir, active)
    full = unit_snapshot(full_dir, active)

    membership_differences(incremental, full) +
      (incremental.keys & full.keys).sort.flat_map { |key| field_differences(key, incremental[key], full[key]) }
  end

  def membership_differences(incremental, full)
    ghosts = incremental.keys - full.keys
    missing = full.keys - incremental.keys

    [ghosts.any? ? "ghost units: #{ghosts.sort.inspect}" : nil,
     missing.any? ? "missing units: #{missing.sort.inspect}" : nil].compact
  end

  def field_differences(key, incremental, full)
    (incremental.keys | full.keys).filter_map do |field|
      next if incremental[field] == full[field]

      "unit #{key} field #{field}: incremental=#{brief(incremental[field])} full=#{brief(full[field])}"
    end
  end

  def type_index_differences(incremental_dir, full_dir, active = default_masks)
    incremental = index_snapshot(incremental_dir, active)
    full = index_snapshot(full_dir, active)

    (incremental.keys | full.keys).sort.filter_map do |type|
      next if incremental[type] == full[type]

      "_index.json for #{type}: incremental=#{brief(incremental[type])} full=#{brief(full[type])}"
    end
  end

  def graph_differences(incremental_dir, full_dir, active = default_masks)
    incremental = graph_snapshot(incremental_dir, active)
    full = graph_snapshot(full_dir, active)

    (incremental.keys | full.keys).filter_map do |section|
      next if incremental[section] == full[section]

      "graph #{section}: #{brief(hash_delta(incremental[section], full[section]))}"
    end
  end

  def manifest_differences(incremental_dir, full_dir, active = default_masks)
    incremental = comparable_manifest(incremental_dir, active)
    full = comparable_manifest(full_dir, active)
    return [] if incremental == full

    ["manifest: #{brief(hash_delta(incremental, full))}"]
  end

  def comparable_manifest(dir, active = default_masks)
    drop_keys(:manifest, read_json(dir, 'manifest.json'), active)
  end

  # The skipped-files report is a pure function of the tree and the unit
  # paths, so it must match byte for byte.
  def skipped_files_differences(incremental_dir, full_dir)
    incremental = read_json(incremental_dir, 'skipped_files.json')
    full = read_json(full_dir, 'skipped_files.json')
    return [] if incremental == full

    ["skipped_files.json: #{brief(hash_delta(incremental, full))}"]
  end

  # The commit table (`git_commits.json`) is a pure function of HEAD, the
  # indexed paths and the bounds. Presence must match too: one run publishing
  # a table and the other none is a difference.
  def commit_table_differences(incremental_dir, full_dir, active = default_masks)
    incremental = drop_keys(:commit_table, read_json(incremental_dir, 'git_commits.json'), active)
    full = drop_keys(:commit_table, read_json(full_dir, 'git_commits.json'), active)
    return [] if incremental == full

    ["git_commits.json: #{brief(hash_delta(incremental, full))}"]
  end

  # SUMMARY.md's totals against the manifest of the SAME index (M4).
  #
  # Compared per directory rather than incremental-vs-full (see the
  # `summary_body` mask). An incremental run used to ship the seeded
  # previous generation's summary unchanged, so its totals went stale the
  # moment the run added or removed units; this check is what keeps that
  # drift from hiding again.
  #
  # Categories is deliberately not compared: the manifest's counts hash may
  # carry types with zero units that the summary's category count excludes,
  # on both paths, for both runs.
  #
  # @param dir [String] index directory
  # @return [Array<String>] differences; empty means the summary agrees
  def summary_differences(dir)
    manifest = read_json(dir, 'manifest.json')
    return [] unless manifest

    path = File.join(payload_dir(dir), 'SUMMARY.md')
    return ['SUMMARY.md is missing but manifest.json is present'] unless File.exist?(path)

    match = Woods::AtomicFile.read(path).match(SUMMARY_TOTALS)
    return ['SUMMARY.md has no totals line'] unless match

    units, chunks = match.captures.map(&:to_i)
    return [] if units == manifest['total_units'] && chunks == manifest['total_chunks']

    ["SUMMARY.md totals (Units: #{units}, Chunks: #{chunks}) disagree with manifest.json " \
     "(total_units: #{manifest['total_units']}, total_chunks: #{manifest['total_chunks']})"]
  end

  SUMMARY_TOTALS = /^Units: (\d+) \| Chunks: (\d+) \| Categories: \d+$/

  def analysis_differences(incremental_dir, full_dir, active = default_masks)
    incremental = analysis_snapshot(incremental_dir, active)
    full = analysis_snapshot(full_dir, active)
    return [] if incremental == full

    ["graph_analysis.json: #{brief(hash_delta(incremental, full))}"]
  end

  # Flow artifacts compared exactly but for the `flow_generated_at` mask
  # (M3): the index and every document it lives beside must agree between a
  # full run and an incremental one. Both writes go through FlowPrecomputer's
  # canonical JSON, so any difference is real drift, not formatting.
  def flow_differences(incremental_dir, full_dir, active = default_masks)
    incremental = flow_snapshot(incremental_dir, active)
    full = flow_snapshot(full_dir, active)

    (incremental.keys | full.keys).sort.filter_map do |name|
      next if incremental[name] == full[name]

      "flow artifact flows/#{name}: incremental=#{brief(incremental[name])} full=#{brief(full[name])}"
    end
  end

  def flow_snapshot(dir, active = default_masks)
    flows_dir = File.join(payload_dir(dir), 'flows')
    return {} unless Dir.exist?(flows_dir)

    Dir[File.join(flows_dir, '*.json')].to_h do |path|
      [File.basename(path), drop_keys(:flow, JSON.parse(Woods::AtomicFile.read(path)), active)]
    end
  end

  # ── Snapshots ────────────────────────────────────────────────────────────

  # All per-unit JSON in an index, keyed by its path on disk — "type/basename".
  #
  # Keyed on the *filename*, not on the identifier inside the file. Keying on
  # content made two real divergences invisible: a leftover file whose
  # identifier a newly-written file also carries collapsed onto one entry with
  # last-write-wins, so a stale unit read as no difference at all; and a run
  # that wrote the right content under the wrong name compared equal while the
  # directories plainly were not. `collision_safe_filename` is a pure function
  # of the identifier, so both sides agree on the name whenever they agree on
  # the unit — which makes this strictly stronger with nothing legitimate lost.
  #
  # The identifier is still compared: it is a field inside the document, so a
  # name/content mismatch now shows up as a field difference rather than
  # vanishing.
  def unit_snapshot(dir, active = default_masks)
    unit_paths(dir).each_with_object({}) do |path, snapshot|
      data = drop_keys(:unit, JSON.parse(Woods::AtomicFile.read(path)), active)
      snapshot["#{File.basename(File.dirname(path))}/#{File.basename(path)}"] = data
    end
  end

  # @return [Array<String>] absolute paths of every unit file in the payload
  def unit_paths(dir)
    Dir[File.join(payload_dir(dir), '*', '*.json')].reject do |path|
      # flows/ holds flow documents, not units — {flow_snapshot} owns them.
      File.basename(path) == '_index.json' || File.basename(File.dirname(path)) == 'flows'
    end
  end

  def index_snapshot(dir, active = default_masks)
    ordered = active.any? { |mask| mask.artifact == :type_index && mask.width == :order }
    Dir[File.join(payload_dir(dir), '*', '_index.json')].each_with_object({}) do |path, snapshot|
      entries = JSON.parse(Woods::AtomicFile.read(path))
      entries = entries.sort_by { |entry| entry['identifier'].to_s } if ordered
      snapshot[File.basename(File.dirname(path))] = entries
    end
  end

  # Every section of the graph file except the `:section` masks, with the
  # `:order` and `:precision` masks applied to theirs. A section the file
  # lacks reads as empty where a mask normalizes it, and is left out
  # otherwise.
  def graph_snapshot(dir, active = default_masks)
    graph = read_json(dir, 'dependency_graph.json')
    return {} unless graph

    masks = active.select { |mask| mask.artifact == :dependency_graph }
    dropped = masks.select { |mask| mask.width == :section }.map { |mask| mask.path.first }
    masks.reject { |mask| mask.width == :section }.each_with_object(graph.except(*dropped)) do |mask, snapshot|
      snapshot[mask.path.first] = normalized_section(mask, graph[mask.path.first])
    end
  end

  # PageRank must be recomputed by incremental runs too, not carried over
  # from the last full extraction (#164 gap 5). Values, not just keys: a
  # modified file re-weights the graph without adding or removing a node,
  # so a carried-over score set has exactly the keys the oracle expects.
  def normalized_section(mask, section)
    case mask.width
    when :order then sorted_values(section) { |members| sort_members(members) }
    when :precision then rounded_pagerank(section, mask.digits)
    end
  end

  def rounded_pagerank(pagerank, digits = PAGERANK_PRECISION)
    (pagerank || {}).transform_values { |score| score.to_f.round(digits) }
  end

  def sorted_values(section, &block)
    (section || {}).transform_values(&block)
  end

  def sort_members(members)
    Array(members).sort_by { |member| member.is_a?(Hash) ? member.to_a : member }
  end

  # Compared **exactly**, ordering included.
  #
  # This used to `deep_sort` both sides, which quietly made the oracle unable
  # to check the thing the analyzer's determinism work was for: if orphans came
  # back in registration order, sorting both sides hid it, and the claim that
  # two extractions of one tree publish identical analysis went unverified by
  # the only test that could verify it. Sorting here and asserting determinism
  # there cannot both be load-bearing.
  def analysis_snapshot(dir, active = default_masks)
    drop_keys(:graph_analysis, read_json(dir, 'graph_analysis.json'), active)
  end

  # ── Masks ────────────────────────────────────────────────────────────────

  def default_masks
    DEFAULT_MASKS.map { |name| mask_named(name) }
  end

  # Remove every active `:key` mask of +artifact+ from +document+.
  def drop_keys(artifact, document, active)
    active.select { |mask| mask.artifact == artifact && mask.width == :key }
          .reduce(document) { |masked, mask| drop_path(masked, mask.path) }
  end

  # A copy of +document+ without the key at +path+; unchanged when a step is
  # missing or is not a Hash.
  def drop_path(document, path)
    return document unless document.is_a?(Hash)

    key, *rest = path
    return document.except(key) if rest.empty?
    return document unless document[key].is_a?(Hash)

    document.merge(key => drop_path(document[key], rest))
  end

  # ── Utilities ────────────────────────────────────────────────────────────

  # Resolve the published generation's payload the way a reader does. An
  # extraction publishes its artifacts into an immutable per-generation
  # directory and names it from generation.json; comparing the flat root would
  # compare whatever a pre-payload run happened to leave there.
  def payload_dir(dir)
    Woods::Generation.new(output_dir: dir).payload_dir.to_s
  end

  def read_json(dir, relative)
    path = File.join(payload_dir(dir), relative)
    File.exist?(path) ? JSON.parse(Woods::AtomicFile.read(path)) : nil
  end

  def deep_sort(value)
    case value
    when Hash then value.transform_values { |nested| deep_sort(nested) }
    when Array then value.map { |nested| deep_sort(nested) }.sort_by(&:to_s)
    else value
    end
  end

  # Keys that differ between two hashes, with both sides' values.
  def hash_delta(left, right)
    return [left, right] unless left.is_a?(Hash) && right.is_a?(Hash)

    (left.keys | right.keys).each_with_object({}) do |key, delta|
      next if left[key] == right[key]

      delta[key] = { incremental: left[key], full: right[key] }
    end
  end

  # Trim a value for a failure message. Raise WOODS_DIFF_BRIEF when a
  # truncated delta isn't enough to see what moved.
  def brief(value)
    text = value.inspect
    limit = Integer(ENV.fetch('WOODS_DIFF_BRIEF', '400'))
    text.length > limit ? "#{text[0, limit]}…" : text
  end
end
