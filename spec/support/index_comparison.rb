# frozen_string_literal: true

require 'json'
require 'woods/generation'

# Compares two Woods index directories and reports every way they differ.
#
# The oracle behind the incremental differential harness (#164): an index
# maintained by `Extractor#extract_changed` has to be indistinguishable from a
# cold `extract_all` of the same tree. This module owns "indistinguishable"
# so the harness spec can stay about *operations*, and so the definition is
# stated once, in one place, with its exclusions justified.
#
# Three kinds of difference are deliberately tolerated, and nothing else:
#
# 1. **Wall-clock stamps** — `extracted_at` on every unit and on the manifest,
#    `generated_at` plus the digest that covers it in `graph_analysis.json`.
#    A unit an incremental run correctly left alone keeps an older stamp.
# 2. **Ordering inside `dependents`** — a full extraction appends in
#    extractor-iteration order, an incremental one in graph order. Both are
#    the same multiset.
# 3. **PageRank beyond {PAGERANK_PRECISION} decimal places** — an iterative
#    float computation, accumulated in whatever order each run registered
#    nodes. Scores are compared as *values*, not just keys; only the last bits
#    are forgiven.
#
# Everything else — unit sets, unit content, `_index.json`, graph nodes,
# edges, reverse edges, file map, type index, stats, PageRank scores, and
# manifest counts — must match exactly.
module IndexComparison # rubocop:disable Metrics/ModuleLength
  VOLATILE_UNIT_KEYS = %w[extracted_at].freeze
  VOLATILE_MANIFEST_KEYS = %w[extracted_at].freeze
  VOLATILE_ANALYSIS_KEYS = %w[generated_at graph_sha].freeze

  module_function

  # @param incremental_dir [String] index maintained by extract_changed
  # @param full_dir [String] index from a cold extract_all of the same tree
  # @return [Array<String>] human-readable differences; empty means equivalent
  def differences(incremental_dir, full_dir)
    unit_differences(incremental_dir, full_dir) +
      type_index_differences(incremental_dir, full_dir) +
      graph_differences(incremental_dir, full_dir) +
      manifest_differences(incremental_dir, full_dir) +
      analysis_differences(incremental_dir, full_dir)
  end

  def unit_differences(incremental_dir, full_dir)
    incremental = unit_snapshot(incremental_dir)
    full = unit_snapshot(full_dir)

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

  def type_index_differences(incremental_dir, full_dir)
    incremental = index_snapshot(incremental_dir)
    full = index_snapshot(full_dir)

    (incremental.keys | full.keys).sort.filter_map do |type|
      next if incremental[type] == full[type]

      "_index.json for #{type}: incremental=#{brief(incremental[type])} full=#{brief(full[type])}"
    end
  end

  def graph_differences(incremental_dir, full_dir)
    incremental = graph_snapshot(incremental_dir)
    full = graph_snapshot(full_dir)

    (incremental.keys | full.keys).filter_map do |section|
      next if incremental[section] == full[section]

      "graph #{section}: #{brief(hash_delta(incremental[section], full[section]))}"
    end
  end

  def manifest_differences(incremental_dir, full_dir)
    incremental = read_json(incremental_dir, 'manifest.json')&.except(*VOLATILE_MANIFEST_KEYS)
    full = read_json(full_dir, 'manifest.json')&.except(*VOLATILE_MANIFEST_KEYS)
    return [] if incremental == full

    ["manifest: #{brief(hash_delta(incremental, full))}"]
  end

  def analysis_differences(incremental_dir, full_dir)
    incremental = analysis_snapshot(incremental_dir)
    full = analysis_snapshot(full_dir)
    return [] if incremental == full

    ["graph_analysis.json: #{brief(hash_delta(incremental, full))}"]
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
  def unit_snapshot(dir)
    Dir[File.join(payload_dir(dir), '*', '*.json')].each_with_object({}) do |path, snapshot|
      next if File.basename(path) == '_index.json'

      data = JSON.parse(File.read(path)).except(*VOLATILE_UNIT_KEYS)
      data['dependents'] = (data['dependents'] || []).sort_by(&:to_a)
      snapshot["#{File.basename(File.dirname(path))}/#{File.basename(path)}"] = data
    end
  end

  def index_snapshot(dir)
    Dir[File.join(payload_dir(dir), '*', '_index.json')].each_with_object({}) do |path, snapshot|
      entries = JSON.parse(File.read(path)).sort_by { |entry| entry['identifier'].to_s }
      snapshot[File.basename(File.dirname(path))] = entries
    end
  end

  def graph_snapshot(dir)
    graph = read_json(dir, 'dependency_graph.json')
    return {} unless graph

    {
      'nodes' => graph['nodes'],
      'edges' => sorted_values(graph['edges']) { |edges| edges.sort_by(&:to_a) },
      'reverse' => sorted_values(graph['reverse'], &:sort),
      'file_map' => sorted_values(graph['file_map']) { |ids| Array(ids).sort },
      'type_index' => sorted_values(graph['type_index'], &:sort),
      'stats' => graph['stats'],
      # PageRank must be recomputed by incremental runs too, not carried over
      # from the last full extraction (#164 gap 5).
      #
      # Values, not just keys. Comparing key sets only catches a *stale node
      # set*, which means it says nothing at all about the ops most likely to
      # leave scores behind: modifying a file re-weights the graph without
      # adding or removing a node, so a carried-over score set has exactly the
      # keys the oracle expects and sails through.
      'pagerank' => rounded_pagerank(graph['pagerank'])
    }
  end

  # PageRank is iterative floating point, so the two runs can accumulate in
  # different orders and disagree in the last bits. Six decimal places is far
  # tighter than any real divergence — a score carried over from a graph that
  # has since changed differs in the first two or three — while leaving no room
  # for float noise to produce a spurious failure.
  PAGERANK_PRECISION = 6

  def rounded_pagerank(pagerank)
    (pagerank || {}).transform_values { |score| score.to_f.round(PAGERANK_PRECISION) }
  end

  def sorted_values(section, &block)
    (section || {}).transform_values(&block)
  end

  # Compared **exactly**, ordering included.
  #
  # This used to `deep_sort` both sides, which quietly made the oracle unable
  # to check the thing the analyzer's determinism work was for: if orphans came
  # back in registration order, sorting both sides hid it, and the claim that
  # two extractions of one tree publish identical analysis went unverified by
  # the only test that could verify it. Sorting here and asserting determinism
  # there cannot both be load-bearing.
  def analysis_snapshot(dir)
    read_json(dir, 'graph_analysis.json')&.except(*VOLATILE_ANALYSIS_KEYS)
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
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
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
