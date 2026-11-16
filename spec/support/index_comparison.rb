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
# `dependency_graph.json` byte for byte, manifest counts, the skipped-files
# report, the commit table, `graph_analysis.json` (including `graph_sha`, the
# digest of the graph file's bytes), flow artifacts, and SUMMARY.md's totals
# against the manifest of the same index — must match exactly.
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
  # - `:value` compares the keys at `path` but not their values.
  # - `:element` removes the string `path.last` from the array at the rest of `path`.
  # - `:artifact` leaves a whole file, or all of it but one checked span, uncompared.
  # - `:representation` covers byte layout: documents are compared as parsed values.
  #
  # An `:artifact` mask, a key mask over {MAX_KEY_SHARE} of its
  # artifact's bytes, or one that empties a document, is *wide* and must say
  # so with its own `wide:` reason.
  class Mask
    WIDTHS = %i[key order value element artifact representation].freeze

    attr_reader :name, :artifact, :path, :width, :reason, :wide

    # @param name [Symbol] unique name, used to select the mask
    # @param artifact [Symbol] a key of {IndexComparison::ARTIFACTS}
    # @param width [Symbol] one of {WIDTHS}
    # @param reason [String] why a full and an incremental run may differ here
    # @param path [Array<String>] keys from the document root to what is masked; `*` matches every key
    # @param wide [String, nil] why this mask may hide more than {MAX_KEY_SHARE}
    # @param default [Boolean] false for a mask only an example names explicitly
    def initialize(name:, artifact:, width:, reason:, path: [], wide: nil, default: true)
      @name = name
      @artifact = artifact
      @width = width
      @reason = reason
      @path = path.freeze
      @wide = wide
      @default = default
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
    Mask.new(name: :type_index_order, artifact: :type_index, width: :order,
             reason: 'Entries are compared sorted by identifier: the index lists units in the order each run ' \
                     'wrote them.'),
    Mask.new(name: :summary_body, artifact: :summary, width: :artifact,
             reason: "Only the totals line is checked, against each index's own manifest (M4). The body " \
                     "carries a Generated: stamp, so the two runs' files never match byte for byte.",
             wide: 'Everything but one line of the file.'),
    Mask.new(name: :source_inputs_generation, artifact: :source_inputs, width: :key, path: %w[generation],
             reason: 'The generation the manifest was published with: an incremental index has published more ' \
                     'of them than a fresh full extraction.'),
    Mask.new(name: :source_inputs_captured_at, artifact: :source_inputs, width: :key, path: %w[captured_at],
             reason: 'Wall-clock stamp of the source capture.'),
    Mask.new(name: :source_inputs_key_id, artifact: :source_inputs, width: :key, path: %w[key_id],
             reason: "Names the output directory's private key; each index has its own."),
    Mask.new(name: :source_inputs_identities, artifact: :source_inputs, width: :key, path: %w[identities],
             reason: "The table of source digests, keyed by the output directory's private key, so two " \
                     'indexes never share one. Which paths each scope records is compared.',
             wide: 'Most of the file: one keyed digest per captured file.'),
    Mask.new(name: :source_inputs_scope_identities, artifact: :source_inputs, width: :value,
             path: %w[scopes * *],
             reason: 'Each recorded path points into the keyed identities table by position. The paths are ' \
                     'compared; the positions are not.'),
    Mask.new(name: :source_inputs_metrics, artifact: :source_inputs, width: :key, path: %w[metrics],
             reason: 'Work accounting of the capture: files visited, hashed and reused from the baseline, bytes ' \
                     'read and elapsed milliseconds. An incremental run reuses earlier digests.'),
    Mask.new(name: :source_inputs_runtime_scope, artifact: :source_inputs, width: :key, path: %w[scopes runtime],
             reason: 'A partial run keeps retained runtime evidence that still refers to the old source, and ' \
                     'boot inputs advance only on a full run (docs/SOURCE_FRESHNESS.md, "Boot inputs advance ' \
                     'only on a full run").'),
    Mask.new(name: :source_inputs_errors_order, artifact: :source_inputs, width: :order, path: %w[errors],
             default: false,
             reason: 'Capture diagnostics in the order each run met them: an incremental run records its ' \
                     "baseline's errors after its own. Opt-in for the fixture that shows it; the set is compared."),
    Mask.new(name: :source_inputs_runtime_uncertainty, artifact: :source_inputs, width: :element,
             path: %w[unverified_scopes runtime_consumption],
             reason: 'A partial run records runtime_consumption when it cannot prove every retained reflected ' \
                     'fact was serialized again (docs/SOURCE_FRESHNESS.md); a full run never does. Every other ' \
                     'uncertainty is compared.'),
    Mask.new(name: :source_reference_identity, artifact: :source_references, width: :key,
             path: %w[files * identity],
             reason: "Each cached file's identity is a digest keyed by the output directory's private key, so " \
                     'two indexes never share it. The cached analysis beside it is compared.'),
    Mask.new(name: :source_reference_added_credit, artifact: :source_references, width: :key,
             path: %w[owners * added], default: false,
             reason: 'Which edges each owner credits to the source-reference pass. Opt-in for one fixture, where ' \
                     'an incremental run credits an edge that a full run reaches without the pass; the edges ' \
                     'themselves are compared in the units and the graph. Not ruled legitimate: an open question ' \
                     'for the maintainer, declared so it stays listed instead of hidden.'),
    Mask.new(name: :outside_payload, artifact: :outside_payload, width: :artifact,
             reason: 'generation.json, locks, the source-input key and the snapshot store record publication ' \
                     'history and process state. The published payload they point at is what is compared.',
             wide: 'Every file outside the published payload directory.'),
    Mask.new(name: :json_representation, artifact: :json, width: :representation,
             reason: 'Documents other than the graph file are compared as parsed values: object key order, ' \
                     'whitespace and number spelling are not.'),
    Mask.new(name: :impact_item_generation, artifact: :impact_report, width: :key, path: %w[generation],
             default: false,
             reason: 'The generation number an impact report item was read from: publication history, not ' \
                     'the content compared beside it.')
  ].freeze

  DEFAULT_MASKS = MASKS.select(&:default?).map(&:name).freeze

  OPEN_QUESTION = 'Not ruled legitimate: an open question for the maintainer, declared per example so it stays ' \
                  'listed instead of hidden. The freshness verifier reports such a path as added or changed, ' \
                  'so the index reads as drifted rather than silently current.'

  # Source-input scope differences seen between an incremental and a full
  # run, by cause. An example names the ones it shows in its
  # `known_source_inputs:` metadata, as `{ cause => { scope => paths } }`, or
  # `{ scope => :missing }` where the paths vary (the randomized sequences):
  # paths only the full run lists are then tolerated in that scope, and no
  # others. Nothing else uses them.
  KNOWN_SOURCE_INPUT_DIFFERENCES = {
    unrun_family_scope: 'A whole-app family the run did not re-execute keeps its baseline scope, so a path the ' \
                        'tree gained since is missing from it (docs/SOURCE_FRESHNESS.md documents the table-family ' \
                        "case). #{OPEN_QUESTION}",
    refresh_family_scope: 'A targeted refresh replaces only the scopes of the families it names; another family ' \
                          'whose rule also matches a new file (test mappings for a rake file, test support for a ' \
                          "factory file) keeps its baseline scope without that file. #{OPEN_QUESTION}",
    unconsumed_file_scope: 'A full run lists every path a family rule matches; an incremental run lists only the ' \
                           'paths an extractor of that family read, so a file none produced a unit from is missing. ' \
                           "#{OPEN_QUESTION}",
    retained_unit_scope: 'A unit scope keeps a path the family no longer builds a unit from: per-file ' \
                         're-extraction adds paths, and only a deletion or a re-run of the whole family removes ' \
                         "them. #{OPEN_QUESTION}",
    deleted_path_kept: 'A renamed-away path stays in the scopes of families the run did not re-execute. ' \
                       "#{OPEN_QUESTION}"
  }.freeze

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

    drop_keys(selected.artifact, document, [selected])
  end

  # @param incremental_dir [String] index maintained by extract_changed
  # @param full_dir [String] index from a cold extract_all of the same tree
  # @param masks [Array<Symbol>] names from {MASKS}; an example may narrow or extend the default set
  # @return [Array<String>] human-readable differences; empty means equivalent
  # @param known [Hash] per-example known differences, see {KNOWN_SOURCE_INPUT_DIFFERENCES}
  def differences(incremental_dir, full_dir, masks: DEFAULT_MASKS, known: {})
    active = active_masks(masks)
    found = compare(incremental_dir, full_dir, masks: masks, known: known)
    report = mask_report(active) + known_report(known)
    warn(report) if found.empty? && ENV['WOODS_DIFF_MASKS'] == '1'
    return found if found.empty?

    warn("IndexComparison: #{incremental_dir} differs from #{full_dir}\n  #{found.join("\n  ")}\n#{report}")
    found + ["not compared: #{(active.map(&:name) + known.keys).join(', ')} " \
             '(reasons on stderr and in IndexComparison::MASKS)']
  end

  # @return [String] the known differences an example declared, with their reasons
  def known_report(known)
    known.map do |cause, scopes|
      "\nKnown source-input difference #{cause} #{scopes.inspect}: #{KNOWN_SOURCE_INPUT_DIFFERENCES.fetch(cause)}"
    end.join
  end

  # {differences} without the report: the raw list, for a caller that expects some.
  #
  # @return [Array<String>]
  def compare(incremental_dir, full_dir, masks: DEFAULT_MASKS, known: {}) # rubocop:disable Metrics/AbcSize
    unknown = known.keys - KNOWN_SOURCE_INPUT_DIFFERENCES.keys
    raise ArgumentError, "no known source-input difference named #{unknown.join(', ')}" if unknown.any?

    active = active_masks(masks)
    nothing_compared(incremental_dir, full_dir) +
      unit_differences(incremental_dir, full_dir, active) +
      type_index_differences(incremental_dir, full_dir, active) +
      graph_differences(incremental_dir, full_dir, active) +
      manifest_differences(incremental_dir, full_dir, active) +
      skipped_files_differences(incremental_dir, full_dir) +
      source_reference_differences(incremental_dir, full_dir, active) +
      commit_table_differences(incremental_dir, full_dir, active) +
      source_input_differences(incremental_dir, full_dir, active, known) +
      analysis_differences(incremental_dir, full_dir, active) +
      flow_differences(incremental_dir, full_dir, active) +
      summary_differences(incremental_dir) +
      summary_differences(full_dir)
  end

  # Resolve names to masks. An `:artifact` or `:representation`
  # mask has no comparison behind it to fall back on, so it cannot be lifted.
  #
  # @return [Array<Mask>]
  def active_masks(names)
    missing = MASKS.select { |mask| mask.default? && UNLIFTABLE.include?(mask.width) }.map(&:name) - names
    raise ArgumentError, "no comparison exists for #{missing.join(', ')}: they cannot be lifted" if missing.any?

    names.map { |name| mask_named(name) }
  end

  UNLIFTABLE = %i[artifact representation].freeze

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

  # Compared byte for byte: both paths serialize the graph key-sorted
  # (B-180), PageRank included, and `graph_sha` publishes a digest of exactly
  # these bytes. The sections are parsed only to name the one that moved.
  def graph_differences(incremental_dir, full_dir, _active = nil)
    incremental, full = [incremental_dir, full_dir].map { |dir| read_text(dir, 'dependency_graph.json') }
    return [] if incremental == full

    left, right = [incremental, full].map { |text| text && JSON.parse(text) }
    return ["graph: incremental=#{brief(left)} full=#{brief(right)}"] unless left.is_a?(Hash) && right.is_a?(Hash)

    graph_section_differences(left, right)
  end

  def graph_section_differences(left, right)
    moved = (left.keys | right.keys).reject { |section| left[section] == right[section] }
    return ['graph bytes differ while every section parses equal (key order, spacing or number form)'] if moved.empty?

    moved.map { |section| "graph #{section}: #{brief(hash_delta(left[section], right[section]))}" }
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

  # The source-reference cache carries the per-file analysis an incremental
  # run reuses, so it must match a full run's apart from its keyed identities.
  def source_reference_differences(incremental_dir, full_dir, active = default_masks)
    incremental = drop_keys(:source_references, read_json(incremental_dir, 'source_references.json'), active)
    full = drop_keys(:source_references, read_json(full_dir, 'source_references.json'), active)
    return [] if incremental == full

    ["source_references.json: #{brief(hash_delta(incremental, full))}"]
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

  # The source-input manifest records which source each consumer scope
  # proved; apart from its keys, stamps and the documented runtime case it
  # must list what a full run lists.
  def source_input_differences(incremental_dir, full_dir, active = default_masks, known = {})
    incremental = drop_keys(:source_inputs, read_json(incremental_dir, 'source_inputs.json'), active)
    full = drop_keys(:source_inputs, read_json(full_dir, 'source_inputs.json'), active)
    return [] if incremental == full
    return ["source_inputs.json: #{brief(hash_delta(incremental, full))}"] unless incremental && full

    rest = hash_delta(incremental.except('scopes'), full.except('scopes'))
    scopes = tolerate_known(incremental.fetch('scopes', {}), full.fetch('scopes', {}), known)
    (rest.empty? ? [] : ["source_inputs.json: #{brief(rest)}"]) + scope_differences(*scopes)
  end

  # Both sides' scopes without the paths an example declared as known.
  def tolerate_known(incremental, full, known)
    known.each_value.reduce([incremental, full]) do |(left, right), scopes|
      scopes.each_with_object([left.dup, right.dup]) do |(scope, paths), (kept_left, kept_right)|
        mine = kept_left.fetch(scope, {})
        theirs = kept_right.fetch(scope, {})
        dropped = paths == :missing ? theirs.keys - mine.keys : Array(paths)
        kept_left[scope] = mine.except(*dropped) if kept_left.key?(scope)
        kept_right[scope] = theirs.except(*dropped) if kept_right.key?(scope)
      end
    end
  end

  # One line per consumer scope whose recorded paths differ.
  def scope_differences(incremental, full)
    (incremental.keys | full.keys).sort.filter_map do |scope|
      left = incremental.fetch(scope, {})
      right = full.fetch(scope, {})
      next if left == right

      "source_inputs.json scope #{scope}: only incremental #{brief((left.keys - right.keys).sort)}, " \
        "only full #{brief((right.keys - left.keys).sort)}#{', values differ' if left.keys.sort == right.keys.sort}"
    end
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

  # Apply every active `:key`, `:value` and `:element` mask of +artifact+ to +document+.
  def drop_keys(artifact, document, active)
    active.select { |mask| mask.artifact == artifact }.reduce(document) do |masked, mask|
      case mask.width
      when :key then drop_path(masked, mask.path)
      when :value then blank_path(masked, mask.path)
      when :order then sort_at(masked, mask.path)
      when :element then drop_element(masked, mask.path[0...-1], mask.path.last)
      else masked
      end
    end
  end

  # A copy of +document+ with the array at +path+ in a canonical order.
  def sort_at(document, path)
    return document if path.empty? || !document.is_a?(Hash) || !document.key?(path.first)

    key, *rest = path
    value = document[key]
    document.merge(key => rest.empty? ? Array(value).sort_by { |member| JSON.generate(member) } : sort_at(value, rest))
  end

  # A copy of +document+ with the value at +path+ replaced by nil, its key kept.
  def blank_path(document, path)
    return document unless document.is_a?(Hash)

    key, *rest = path
    keys = key == '*' ? document.keys : [key] & document.keys
    keys.reduce(document) do |copy, name|
      copy.merge(name => rest.empty? ? nil : blank_path(copy[name], rest))
    end
  end

  # A copy of +document+ whose array at +path+ no longer holds +element+.
  def drop_element(document, path, element)
    return document unless document.is_a?(Hash)

    key, *rest = path
    return document unless document.key?(key)

    value = document[key]
    document.merge(key => rest.empty? ? Array(value) - [element] : drop_element(value, rest, element))
  end

  # Every member of a Hash or an Array, replaced by the block's answer.
  def each_member(collection, &block)
    collection.is_a?(Array) ? collection.map(&block) : collection.transform_values(&block)
  end

  # A copy of +document+ without the key at +path+; unchanged when a step is
  # missing or is not a Hash. A `*` step stands for every member of a Hash or an Array.
  def drop_path(document, path)
    key, *rest = path
    return each_member(document) { |value| drop_path(value, rest) } if key == '*' && document.is_a?(Enumerable)
    return document unless document.is_a?(Hash)
    return document.except(key) if rest.empty?
    return document unless document[key].is_a?(Enumerable)

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
    text = read_text(dir, relative)
    text && JSON.parse(text)
  end

  def read_text(dir, relative)
    path = File.join(payload_dir(dir), relative)
    File.exist?(path) ? Woods::AtomicFile.read(path) : nil
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
