# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

RSpec.describe IndexComparison do
  # A flat (pre-payload) index: Generation resolves its payload to the root.
  def write_index(dir, note:)
    FileUtils.mkdir_p(File.join(dir, 'models'))
    FileUtils.mkdir_p(File.join(dir, 'flows'))
    unit = { 'identifier' => 'Widget', 'type' => 'model', 'source_code' => "class Widget # #{note}\nend\n",
             'extracted_at' => '2026-01-01T00:00:00Z' }
    File.write(File.join(dir, 'models', 'Widget.json'), JSON.generate(unit), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'models', '_index.json'),
               JSON.generate([{ 'identifier' => 'Widget', 'summary' => note }]), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'flows', 'flow_index.json'),
               JSON.generate('generated_at' => '2026', 'flows' => { 'name' => note }), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'manifest.json'),
               JSON.generate('total_units' => 1, 'total_chunks' => 1, 'note' => note), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'dependency_graph.json'),
               JSON.generate('nodes' => { 'Widget' => { 'note' => note } }), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'graph_analysis.json'), JSON.generate('orphans' => [note]), encoding: Encoding::UTF_8)
    File.write(File.join(dir, 'SUMMARY.md'), "# Woods Index #{note}\n\nUnits: 1 | Chunks: 1 | Categories: 1\n",
               encoding: Encoding::UTF_8)
  end

  it 'compares indexes holding multibyte text under a POSIX default external encoding' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'façade → ledger')
      write_index(right, note: 'façade → ledger')

      differences = with_posix_default_external { described_class.differences(left, right) }

      expect(differences).to eq([])
    end
  end

  it 'compares commit tables, tolerating only the window start day' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'same')
      write_index(right, note: 'same')
      table = { 'head' => 'a' * 40, 'since' => '2025-10-23', 'commits' => [], 'paths' => {} }
      File.write(File.join(left, 'git_commits.json'), JSON.generate(table))

      expect(described_class.compare(left, right)).to include(a_string_starting_with('git_commits.json'))

      File.write(File.join(right, 'git_commits.json'), JSON.generate(table.merge('since' => '2025-10-24')))
      expect(described_class.differences(left, right)).to eq([])

      File.write(File.join(right, 'git_commits.json'), JSON.generate(table.merge('head' => 'b' * 40)))
      expect(described_class.compare(left, right)).to include(a_string_starting_with('git_commits.json'))
    end
  end

  describe 'the mask table' do
    it 'declares each mask once, with a known artifact and width and a reason' do
      names = described_class::MASKS.map(&:name)
      expect(names).to eq(names.uniq)
      described_class::MASKS.each do |mask|
        expect(described_class::ARTIFACTS).to have_key(mask.artifact)
        expect(described_class::Mask::WIDTHS).to include(mask.width)
        expect(mask.reason.to_s.strip).not_to be_empty, "#{mask.name} has no reason"
      end
    end

    it 'gives every whole-section and whole-artifact mask its own wide reason' do
      described_class::MASKS.select { |mask| %i[section artifact].include?(mask.width) }.each do |mask|
        expect(mask.wide).to be_a(String).and(satisfy { |text| !text.strip.empty? && text != mask.reason })
      end
    end

    it 'leaves opt-in masks out of the default comparison' do
      expect(described_class::DEFAULT_MASKS).not_to include(:impact_item_generation)
      expect(described_class.mask(:impact_item_generation, 'generation' => 3, 'path' => 'a'))
        .to eq('path' => 'a')
      expect { described_class.mask(:type_index_order, {}) }.to raise_error(ArgumentError, /not a key mask/)
      # A missing document must not compare equal to another missing one.
      expect { described_class.mask(:unit_extracted_at, nil) }.to raise_error(ArgumentError, /masks a Hash, not nil/)
    end
  end

  describe 'a red comparison' do
    def red_pair(root)
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'one')
      write_index(right, note: 'two')
      [left, right]
    end

    it 'ends with the masks in effect and prints their reasons' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        found = nil
        expect { found = described_class.differences(*red_pair(root)) }
          .to output(%r{masks in effect.*unit_extracted_at \(key: <type>/<unit>\.json extracted_at\): Wall-clock}m)
          .to_stderr
        expect(found.last).to start_with('not compared: ').and include(*described_class::DEFAULT_MASKS.map(&:to_s))
      end
    end

    it 'reports a field a narrower mask set no longer drops' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        left = File.join(root, 'incremental')
        right = File.join(root, 'full')
        write_index(left, note: 'same')
        write_index(right, note: 'same')
        unit = File.join(left, 'models', 'Widget.json')
        File.write(unit, JSON.generate(JSON.parse(File.read(unit)).merge('extracted_at' => '2027-01-01T00:00:00Z')))

        expect(described_class.compare(left, right)).to eq([])
        narrowed = described_class::DEFAULT_MASKS - [:unit_extracted_at]
        expect(described_class.compare(left, right, masks: narrowed))
          .to contain_exactly(a_string_starting_with('unit models/Widget.json field extracted_at'))
        expect { described_class.compare(left, right, masks: described_class::DEFAULT_MASKS - [:summary_body]) }
          .to raise_error(ArgumentError, /summary_body: they cannot be lifted/)
      end
    end

    it 'compares the graph file byte for byte, and names a section that moved' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        left = File.join(root, 'incremental')
        right = File.join(root, 'full')
        write_index(left, note: 'same')
        write_index(right, note: 'same')
        graph = File.join(right, 'dependency_graph.json')
        File.write(graph, JSON.pretty_generate(JSON.parse(File.read(graph))))

        expect(described_class.compare(left, right))
          .to eq(['graph bytes differ while every section parses equal (key order, spacing or number form)'])
        File.write(graph, JSON.generate('nodes' => { 'Widget' => { 'note' => 'moved' } }))
        expect(described_class.compare(left, right)).to contain_exactly(a_string_starting_with('graph nodes: '))
      end
    end

    it 'compares the source-reference cache except its keyed identities' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        left = File.join(root, 'incremental')
        right = File.join(root, 'full')
        write_index(left, note: 'same')
        write_index(right, note: 'same')
        cache = lambda do |identity, analysis|
          { 'files' => { 'a.rb' => { 'identity' => identity, 'analysis' => analysis } } }
        end
        File.write(File.join(left, 'source_references.json'), JSON.generate(cache.call('a' * 64, ['Post'])))
        File.write(File.join(right, 'source_references.json'), JSON.generate(cache.call('b' * 64, ['Post'])))

        expect(described_class.compare(left, right)).to eq([])
        File.write(File.join(right, 'source_references.json'), JSON.generate(cache.call('b' * 64, ['Comment'])))
        expect(described_class.compare(left, right))
          .to contain_exactly(a_string_starting_with('source_references.json: '))
      end
      owners = { 'owners' => [{ 'identifier' => 'A', 'added' => [{ 'target' => 'B' }] }] }
      expect(described_class.mask(:source_reference_added_credit, owners)).to eq('owners' => [{ 'identifier' => 'A' }])
    end

    describe 'the source-input manifest' do
      def inputs(scopes, unverified: [])
        { 'generation' => 1, 'key_id' => 'k', 'identities' => %w[d0 d1], 'scopes' => scopes,
          'unverified_scopes' => unverified, 'complete' => true }
      end

      def pair(root, left, right)
        dirs = %w[incremental full].map { |name| File.join(root, name) }
        dirs.zip([left, right]).each do |dir, document|
          write_index(dir, note: 'same')
          File.write(File.join(dir, 'source_inputs.json'), JSON.generate(document))
        end
        dirs
      end

      it 'compares recorded paths and uncertainties, not keyed positions or the runtime case' do
        Dir.mktmpdir('woods-index-comparison') do |root|
          left = inputs({ 'file:services' => { 'a.rb' => 0 }, 'runtime' => { 'a.rb' => 0 } },
                        unverified: ['runtime_consumption'])
          right = inputs({ 'file:services' => { 'a.rb' => 1 }, 'runtime' => {} }).merge('generation' => 2)
          expect(described_class.compare(*pair(root, left, right))).to eq([])
        end
        Dir.mktmpdir('woods-index-comparison') do |root|
          left = inputs({ 'file:services' => { 'a.rb' => 0 } }, unverified: ['extractor:services'])
          right = inputs({ 'file:services' => { 'a.rb' => 0, 'b.rb' => 1 } })
          expect(described_class.compare(*pair(root, left, right))).to contain_exactly(
            a_string_including('unverified_scopes'),
            'source_inputs.json scope file:services: only incremental [], only full ["b.rb"]'
          )
        end
      end

      it 'tolerates only the known differences an example names' do
        Dir.mktmpdir('woods-index-comparison') do |root|
          dirs = pair(root, inputs({ 'whole:events' => {}, 'unit:poros' => { 'c.rb' => 0 } }),
                      inputs({ 'whole:events' => { 'b.rb' => 1 }, 'unit:poros' => {} }))
          missing = { unrun_family_scope: { 'whole:events' => :missing } }
          exact = missing.merge(retained_unit_scope: { 'unit:poros' => %w[c.rb] })

          expect(described_class.compare(*dirs, known: missing))
            .to eq(['source_inputs.json scope unit:poros: only incremental ["c.rb"], only full []'])
          expect(described_class.compare(*dirs, known: exact)).to eq([])
          errors = [{ 'reason' => 'b' }, { 'reason' => 'a' }]
          reordered = pair(File.join(root, 'order'), inputs({}).merge('errors' => errors),
                           inputs({}).merge('errors' => errors.reverse))
          expect(described_class.compare(*reordered)).to contain_exactly(a_string_including('errors'))
          ordered = described_class::DEFAULT_MASKS + %i[source_inputs_errors_order]
          expect(described_class.compare(*reordered, masks: ordered)).to eq([])
          error = { 'reason' => 'loaded_source_outside_coverage', 'path' => 'x.rb' }
          carried = pair(File.join(root, 'carried'), inputs({}).merge('errors' => [error]),
                         inputs({}).merge('errors' => []))
          expect(described_class.compare(*carried)).to contain_exactly(a_string_including('errors'))
          carried_known = { baseline_error_carried: { 'errors' => %w[x.rb] } }
          expect(described_class.compare(*carried, known: carried_known)).to eq([])
          expect { described_class.compare(*dirs, known: { invented: {} }) }
            .to raise_error(ArgumentError, /no known source-input difference named invented/)
        end
      end
    end

    it 'prints the masks on success only when asked' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        left = File.join(root, 'incremental')
        write_index(left, note: 'same')
        right = File.join(root, 'full')
        write_index(right, note: 'same')

        expect { described_class.differences(left, right) }.not_to output.to_stderr
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('WOODS_DIFF_MASKS').and_return('1')
        expect { described_class.differences(left, right) }.to output(/masks in effect/).to_stderr
      end
    end
  end

  it 'refuses to call two directories without a manifest equivalent' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      expect(described_class.compare(File.join(root, 'a'), File.join(root, 'b')))
        .to contain_exactly(a_string_starting_with('nothing compared'))
    end
  end

  describe IndexComparison::SelfCheck do
    def reference(root)
      dir = File.join(root, 'reference')
      write_index(dir, note: 'reference')
      dir
    end

    it 'answers every probe as required on a small index' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        check = described_class.new(reference(root), File.join(root, 'scratch').tap { |dir| FileUtils.mkdir_p(dir) },
                                    seed: 1)

        expect(check.failures).to be_empty, check.failures.join("\n")
        expect(check.probes.map(&:kind)).to include(:unmasked, :masked, :lifted, :membership)
        expect(check.unclaimed_files).to be_empty
      end
    end

    it 'fails when the comparison stops reporting a unit field' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        check = described_class.new(reference(root), File.join(root, 'scratch').tap { |dir| FileUtils.mkdir_p(dir) },
                                    seed: 1)
        allow(IndexComparison).to receive(:field_differences).and_return([])

        expect(check.failures.map(&:kind)).to include(:unmasked, :lifted)
        expect(check.failures.map(&:artifact).uniq).to eq([:unit])
      end
    end

    it 'fails a mask that hides a large share of an artifact, or a whole document, without declaring it' do
      widened = [IndexComparison::Mask.new(name: :unit_source, artifact: :unit, width: :key, path: %w[source_code],
                                           reason: 'widened'),
                 IndexComparison::Mask.new(name: :analysis_orphans, artifact: :graph_analysis, width: :key,
                                           path: %w[orphans], reason: 'widened')]
      stub_const('IndexComparison::MASKS', IndexComparison::MASKS + widened)
      stub_const('IndexComparison::DEFAULT_MASKS', IndexComparison::DEFAULT_MASKS + widened.map(&:name))
      Dir.mktmpdir('woods-index-comparison') do |root|
        check = described_class.new(reference(root), File.join(root, 'scratch').tap { |dir| FileUtils.mkdir_p(dir) },
                                    seed: 1)

        # The fixture's documents are tiny, so its stamps are over budget too.
        expect(check.budget_violations).to include(
          a_string_starting_with('unit_source removes'),
          a_string_starting_with('analysis_orphans removes'),
          'analysis_orphans leaves a whole document uncompared but declares no wide: reason'
        )
      end
    end

    it 'names a file no artifact or mask accounts for' do
      Dir.mktmpdir('woods-index-comparison') do |root|
        dir = reference(root)
        File.write(File.join(dir, 'new_artifact.json'), '{}')
        check = described_class.new(dir, File.join(root, 'scratch').tap { |path| FileUtils.mkdir_p(path) }, seed: 1)

        expect(check.unclaimed_files).to eq(['new_artifact.json'])
      end
    end
  end

  it 'still reports a multibyte difference under a POSIX default external encoding' do
    Dir.mktmpdir('woods-index-comparison') do |root|
      left = File.join(root, 'incremental')
      right = File.join(root, 'full')
      write_index(left, note: 'façade')
      write_index(right, note: 'fassade')

      differences = with_posix_default_external { described_class.compare(left, right) }

      expect(differences).to include(a_string_starting_with('unit models/Widget.json field source_code'))
      # String#inspect escapes what the default external cannot show.
      expect(differences.join).to include('fa\\u00E7ade').and include('fassade')
    end
  end
end
