# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'index_comparison'

module IndexComparison
  # Proves on a real index that {IndexComparison.compare} can fail, and that
  # every mask in {MASKS} is exactly as wide as declared.
  #
  # Each probe changes one value in a copy of a reference index, compares the
  # copy against the reference, and puts the file back:
  #
  # - `:unmasked`: a value outside every mask. It must be reported, under the
  #   artifact it lives in.
  # - `:masked`: a value inside one mask. It must not be reported.
  # - `:lifted`: the same masked change with that one mask left out of the
  #   comparison. It must be reported again, so the mask is what hid it.
  # - `:membership`: a unit file removed, or one added. It must be reported.
  #
  # The files, keys and values are drawn with a seeded Random, so a run is
  # reproducible from its seed.
  class SelfCheck # rubocop:disable Metrics/ClassLength
    # One change and what the comparison said about it.
    Probe = Struct.new(:kind, :artifact, :file, :path, :mask, :found, keyword_init: true) do
      # @return [Boolean] whether the comparison answered as the probe requires
      def expected?
        return found.empty? if kind == :masked

        found.any? { |line| line.match?(REPORTED_AS.fetch(artifact, //)) }
      end

      # @return [String]
      def to_s
        outcome = found.empty? ? 'no difference' : found.first(2).join(' | ')[0, 300]
        "#{kind} #{artifact} #{file} #{path.inspect}#{" mask=#{mask}" if mask}: #{outcome}"
      end
    end

    # The artifacts the comparison reads, each with how its differences start.
    REPORTED_AS = {
      unit: /\A(unit |ghost units|missing units)/,
      type_index: /\A_index\.json /,
      dependency_graph: /\Agraph[ :]/,
      manifest: /\Amanifest: /,
      skipped_files: /\Askipped_files\.json: /,
      commit_table: /\Agit_commits\.json: /,
      graph_analysis: /\Agraph_analysis\.json: /,
      flow: %r{\Aflow artifact flows/},
      summary: /\ASUMMARY\.md /,
      source_references: /\Asource_references\.json: /
    }.freeze

    SINGLE_FILES = {
      'dependency_graph.json' => :dependency_graph, 'manifest.json' => :manifest,
      'skipped_files.json' => :skipped_files, 'git_commits.json' => :commit_table,
      'graph_analysis.json' => :graph_analysis, 'SUMMARY.md' => :summary,
      'source_inputs.json' => :source_inputs, 'source_references.json' => :source_references
    }.freeze

    # How many unit directories, and type indexes, the unmasked probes sample.
    SAMPLED_TYPES = 4

    # @param reference_dir [String] a published index; never modified
    # @param scratch_dir [String] an empty directory for the copy
    # @param seed [Integer]
    def initialize(reference_dir, scratch_dir, seed:)
      @reference = reference_dir
      @copy = File.join(scratch_dir, 'self_check_copy')
      FileUtils.cp_r(reference_dir, @copy)
      @payload = IndexComparison.payload_dir(@copy)
      @random = Random.new(seed)
      @masks = IndexComparison.default_masks
    end

    # @return [Array<Probe>] every probe, run once
    def probes
      @probes ||= [baseline_probe] + unmasked_probes + masked_probes + membership_probes + [baseline_probe]
    end

    # @return [Array<Probe>] probes the comparison answered wrongly
    def failures
      probes.reject(&:expected?)
    end

    # @return [Array<Symbol>] compared artifacts no unmasked probe reached
    def uncovered_artifacts
      REPORTED_AS.keys - probes.select { |probe| probe.kind == :unmasked }.map(&:artifact)
    end

    # @return [Array<Symbol>] default masks no masked probe reached
    def unexercised_masks
      @masks.map(&:name) - probes.select { |probe| probe.kind == :masked }.map(&:mask)
    end

    # @return [Array<String>] payload files no artifact or mask accounts for
    def unclaimed_files
      payload_files.reject { |relative| artifact_of(relative) }
    end

    # The share of its artifact's JSON bytes each `:key` mask removes, over
    # every document of the artifact. Summed rather than per document: a
    # fixed-size stamp is a large share of a small flow document without
    # hiding anything more, and which documents exist depends on the tree.
    #
    # @return [Hash{Symbol => Float}]
    def key_mask_shares
      @masks.select { |mask| mask.width == :key }.to_h do |mask|
        sizes = documents(mask.artifact).filter_map { |_relative, document| masked_bytes(document, mask.path) }
        [mask.name, sizes.sum(&:first).fdiv([sizes.sum(&:last), 1].max)]
      end
    end

    # Key masks that leave some document with nothing to compare.
    #
    # @return [Array<Symbol>]
    def whole_document_masks
      @masks.select { |mask| mask.width == :key && !mask.wide? && empties_a_document?(mask) }.map(&:name)
    end

    # Masks wider than the budget without saying so.
    #
    # @return [Array<String>]
    def budget_violations
      shape_violations + share_violations +
        whole_document_masks.map { |name| "#{name} leaves a whole document uncompared but declares no wide: reason" }
    end

    private

    MISSING = Object.new.freeze
    private_constant :MISSING

    # @return [(Integer, Integer), nil] bytes under +pattern+ and in the document, nil when nothing matches
    def masked_bytes(document, pattern)
      paths = concrete_paths(document, pattern)
      return nil if paths.empty?

      [paths.sum { |path| JSON.generate(dig(document, path)).bytesize }, JSON.generate(document).bytesize]
    end

    def shape_violations
      MASKS.filter_map do |mask|
        next unless %i[section artifact].include?(mask.width) && !mask.wide?

        "#{mask.name} drops a whole #{mask.width} but declares no wide: reason"
      end
    end

    def share_violations
      key_mask_shares.filter_map do |name, share|
        next if share <= MAX_KEY_SHARE || IndexComparison.mask_named(name).wide?

        "#{name} removes #{(share * 100).round(1)}% of its artifact's bytes (budget " \
          "#{(MAX_KEY_SHARE * 100).round}%) but declares no wide: reason"
      end
    end

    def empties_a_document?(mask)
      documents(mask.artifact).any? do |_relative, document|
        document.is_a?(Hash) && document.any? && IndexComparison.drop_path(document, mask.path).empty?
      end
    end

    def baseline_probe
      Probe.new(kind: :masked, artifact: :baseline, file: '(none)', path: [], found: compare)
    end

    def compare(masks: IndexComparison::DEFAULT_MASKS)
      IndexComparison.compare(@copy, @reference, masks: masks)
    end

    # ── Unmasked ─────────────────────────────────────────────────────────

    def unmasked_probes
      sampled_files.flat_map do |relative|
        artifact = artifact_of(relative)
        next summary_probe(relative) if artifact == :summary

        document = read(relative)
        top_level_slots(document).filter_map do |slot|
          path = unmasked_leaf(artifact, document, slot)
          next unless path

          probe(:unmasked, artifact, relative, path, nil) { write(relative, mutate_at(document, path)) }
        end
      end
    end

    # A few unit directories and type indexes, and every other compared file.
    def sampled_files
      grouped = payload_files.group_by { |relative| artifact_of(relative) }.slice(*REPORTED_AS.keys)
      indexes = grouped.fetch(:type_index, []).reject { |relative| read(relative).empty? }
      sampled_units(grouped.fetch(:unit, [])) + indexes.sample(SAMPLED_TYPES, random: @random) +
        grouped.except(:unit, :type_index).values.flatten.sort
    end

    # One unit file from each of a few unit directories.
    def sampled_units(files)
      by_type = files.group_by { |relative| File.dirname(relative) }
      by_type.keys.sort.sample(SAMPLED_TYPES, random: @random).map { |dir| by_type.fetch(dir).sample(random: @random) }
    end

    # Each top-level key of a document, or the whole of an array document.
    def top_level_slots(document)
      document.is_a?(Hash) ? document.keys.map { |key| [key] } : [[]]
    end

    # A leaf under +slot+ outside every mask, or the slot itself when it holds
    # an empty container. nil when the whole slot is masked.
    def unmasked_leaf(artifact, document, slot)
      return nil if masked_path?(artifact, slot)

      leaves = leaf_paths(dig(document, slot), slot).reject { |path| masked_path?(artifact, path) }
      leaves.empty? ? slot : leaves.sample(random: @random)
    end

    def summary_probe(relative)
      path = File.join(@payload, relative)
      text = File.read(path, encoding: 'UTF-8')
      totals = text[SUMMARY_TOTALS]
      changed = text.sub(totals, totals.sub(/Units: (\d+)/) { "Units: #{Integer(::Regexp.last_match(1)) + 1}" })
      [probe(:unmasked, :summary, relative, ['totals line'], nil) { File.write(path, changed) }]
    end

    # ── Masked and lifted ────────────────────────────────────────────────

    def masked_probes
      @masks.flat_map { |mask| [send(:"#{mask.width}_probes", mask)].flatten.compact }
    end

    def key_probes(mask)
      candidates = documents(mask.artifact).reject { |_name, document| concrete_paths(document, mask.path).empty? }
      relative, document = candidates.sort_by(&:first).sample(random: @random)
      return [] unless relative

      target = concrete_paths(document, mask.path).sample(random: @random)
      leaves = leaf_paths(dig(document, target), target)
      path = leaves.empty? ? target : leaves.sample(random: @random)
      changed = mutate_at(document, path)
      masked_and_lifted(mask, relative, path) { write(relative, changed) }
    end

    def order_probes(mask)
      candidates = documents(mask.artifact).sort_by(&:first).flat_map do |relative, document|
        order_targets(mask, document).map { |path| [relative, document, path] }
      end
      relative, document, path = candidates.sample(random: @random)
      return [] unless relative

      changed = replace_at(document, path, dig(document, path).reverse)
      masked_and_lifted(mask, relative, path) { write(relative, changed) }
    end

    # Arrays under the mask whose reversal changes them.
    def order_targets(mask, document)
      return reorderable?(document) ? [[]] : [] if mask.path.empty?

      section = dig(document, mask.path)
      return [] unless section.is_a?(Hash)

      section.keys.select { |key| reorderable?(section[key]) }.map { |key| mask.path + [key] }
    end

    def reorderable?(members)
      members.is_a?(Array) && members.reverse != members
    end

    def masked_and_lifted(mask, relative, path, &change)
      lifted = IndexComparison::DEFAULT_MASKS - [mask.name]
      [probe(:masked, mask.artifact, relative, path, mask.name, &change),
       probe(:lifted, mask.artifact, relative, path, mask.name, masks: lifted, &change)]
    end

    def artifact_probes(mask)
      case mask.artifact
      when :summary then summary_body_probe(mask)
      when :outside_payload then outside_payload_probe(mask)
      else
        relative = SINGLE_FILES.key(mask.artifact)
        return nil unless payload_files.include?(relative)

        document = read(relative)
        changed = mutate_at(document, leaf_paths(document, []).sample(random: @random))
        probe(:masked, mask.artifact, relative, [], mask.name) { write(relative, changed) }
      end
    end

    def summary_body_probe(mask)
      path = File.join(@payload, 'SUMMARY.md')
      lines = File.read(path, encoding: 'UTF-8').lines
      line = lines.each_index.reject { |index| lines[index].match?(SUMMARY_TOTALS) }.sample(random: @random)
      changed = lines.dup.tap { |copy| copy[line] = "#{copy[line].chomp} (changed)\n" }.join
      probe(:masked, :summary, 'SUMMARY.md', ["line #{line + 1}"], mask.name) { File.write(path, changed) }
    end

    def outside_payload_probe(mask)
      stray = File.join(@copy, 'self_check_stray.json')
      probe(:masked, :outside_payload, File.basename(stray), [], mask.name, cleanup: stray) do
        File.write(stray, '{}')
      end
    end

    # The same document, rewritten pretty-printed with its keys reversed.
    def representation_probes(mask)
      relative = payload_files.select { |file| artifact_of(file) == :unit }.min
      document = read(relative)
      reordered = document.to_a.reverse.to_h
      probe(:masked, :json, relative, [], mask.name) do
        File.write(File.join(@payload, relative), JSON.pretty_generate(reordered))
      end
    end

    # ── Membership ───────────────────────────────────────────────────────

    def membership_probes
      relative = payload_files.select { |file| artifact_of(file) == :unit }.sort.sample(random: @random)
      added = File.join(File.dirname(relative), 'SelfCheckAddedUnit.json')
      [probe(:membership, :unit, relative, ['removed'], nil) { File.delete(File.join(@payload, relative)) },
       probe(:membership, :unit, added, ['added'], nil, cleanup: File.join(@payload, added)) do
         FileUtils.cp(File.join(@payload, relative), File.join(@payload, added))
       end]
    end

    # ── Running one probe ────────────────────────────────────────────────

    # Change the copy, compare, and restore the file the change touched.
    def probe(kind, artifact, file, path, mask, masks: IndexComparison::DEFAULT_MASKS, cleanup: nil)
      target = cleanup || File.join(@payload, file)
      original = File.exist?(target) && !cleanup ? File.binread(target) : nil
      yield
      Probe.new(kind: kind, artifact: artifact, file: file, path: path, mask: mask, found: compare(masks: masks))
    ensure
      original ? File.binwrite(target, original) : FileUtils.rm_f(cleanup)
    end

    # ── Documents ────────────────────────────────────────────────────────

    def payload_files
      @payload_files ||= Dir.glob(File.join(@payload, '**', '*'), File::FNM_DOTMATCH)
                            .select { |path| File.file?(path) }
                            .map { |path| path.delete_prefix("#{@payload}/") }.sort
    end

    def artifact_of(relative)
      return SINGLE_FILES.fetch(relative) if SINGLE_FILES.key?(relative)

      case relative
      when %r{\Aflows/[^/]+\.json\z} then :flow
      when %r{\A[^/]+/_index\.json\z} then :type_index
      when %r{\A[^/]+/[^/]+\.json\z} then :unit
      end
    end

    # @return [Array<(String, Object)>] every document of an artifact, parsed
    def documents(artifact)
      payload_files.select { |relative| artifact_of(relative) == artifact }
                   .map { |relative| [relative, read(relative)] }
    end

    def read(relative)
      JSON.parse(Woods::AtomicFile.read(File.join(@payload, relative)))
    end

    def write(relative, document)
      File.write(File.join(@payload, relative), JSON.generate(document))
    end

    def masked_path?(artifact, path)
      @masks.any? do |mask|
        mask.artifact == artifact && mask.width == :key && within?(path, mask.path)
      end
    end

    # Whether +path+ lies at or under +pattern+, a `*` step matching any key.
    def within?(path, pattern)
      path.size >= pattern.size && pattern.each_with_index.all? { |step, index| ['*', path[index]].include?(step) }
    end

    # Every existing path in +document+ that +pattern+ names, `*` expanded.
    def concrete_paths(document, pattern, prefix = [])
      return [prefix] if pattern.empty?

      step, *rest = pattern
      return [] unless document.is_a?(Hash)

      keys = step == '*' ? document.keys : [step] & document.keys
      keys.flat_map { |key| concrete_paths(document[key], rest, prefix + [key]) }
    end

    # Paths to every scalar under +value+, and to every empty container.
    def leaf_paths(value, prefix)
      children = case value
                 when Hash then value.map { |key, child| [prefix + [key], child] }
                 when Array then value.each_with_index.map { |child, index| [prefix + [index], child] }
                 else return [prefix]
                 end
      children.empty? ? [prefix] : children.flat_map { |path, child| leaf_paths(child, path) }
    end

    def dig(document, path)
      path.reduce(document) do |node, step|
        return MISSING unless (node.is_a?(Hash) && node.key?(step)) || (node.is_a?(Array) && step.is_a?(Integer))

        node[step]
      end
    end

    def mutate_at(document, path)
      replace_at(document, path, mutate(dig(document, path)))
    end

    # One value changed: the last character of a string, a number by one, a
    # boolean flipped, an empty container filled.
    def mutate(value)
      case value
      when String then mutate_text(value)
      when Numeric then value + 1
      when Hash then value.merge('self_check' => 1)
      when Array then value + ['self_check']
      else MUTATED.fetch(value)
      end
    end

    MUTATED = { true => false, false => true, nil => 'x' }.freeze
    private_constant :MUTATED

    def mutate_text(text)
      return 'x' if text.empty?

      text.sub(/.\z/m) { |last| last == 'x' ? 'y' : 'x' }
    end

    def replace_at(document, path, value)
      return value if path.empty?

      head, *rest = path
      copy = document.dup
      copy[head] = replace_at(document[head], rest, value)
      copy
    end
  end
end
