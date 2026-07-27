# frozen_string_literal: true

require 'json'

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
# 3. **Ordering inside `graph_analysis.json` lists** — orphans, hubs, cycles
#    and bridges are emitted in graph-registration order, and an incremental
#    run appends a new node where a full run would interleave it. Membership
#    is what those lists mean.
#
# Everything else — unit sets, unit content, `_index.json`, graph nodes,
# edges, reverse edges, file map, type index, stats, PageRank coverage, and
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

  # All per-unit JSON in an index, keyed "type/identifier".
  def unit_snapshot(dir)
    Dir[File.join(dir, '*', '*.json')].each_with_object({}) do |path, snapshot|
      next if File.basename(path) == '_index.json'

      data = JSON.parse(File.read(path)).except(*VOLATILE_UNIT_KEYS)
      data['dependents'] = (data['dependents'] || []).sort_by(&:to_a)
      snapshot["#{File.basename(File.dirname(path))}/#{data['identifier']}"] = data
    end
  end

  def index_snapshot(dir)
    Dir[File.join(dir, '*', '_index.json')].each_with_object({}) do |path, snapshot|
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
      'pagerank_keys' => graph['pagerank']&.keys&.sort
    }
  end

  def sorted_values(section, &block)
    (section || {}).transform_values(&block)
  end

  def analysis_snapshot(dir)
    deep_sort(read_json(dir, 'graph_analysis.json')&.except(*VOLATILE_ANALYSIS_KEYS))
  end

  # ── Utilities ────────────────────────────────────────────────────────────

  def read_json(dir, relative)
    path = File.join(dir, relative)
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
