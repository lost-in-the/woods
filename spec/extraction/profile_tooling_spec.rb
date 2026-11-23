# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'woods/mcp/search_results'

load File.expand_path('../../bench/ab_alternating_compare.rb', __dir__)
load File.expand_path('../../bench/full_and_incremental_profile.rb', __dir__)

RSpec.describe 'Woods profiling and A/B comparison tooling' do
  let(:compare_script) { File.expand_path('../../script/profile-compare', __dir__) }

  describe 'WoodsABCompare' do
    it 'rejects zero and negative --pairs counts before running' do
      expect { WoodsABCompare.parse_options(%w[--base /tmp/a --cand /tmp/b --pairs 0]) }
        .to raise_error(ArgumentError, /--pairs must be >= 1/)
      expect { WoodsABCompare.parse_options(%w[--base /tmp/a --cand /tmp/b --pairs -2]) }
        .to raise_error(ArgumentError, /--pairs must be >= 1/)
    end

    it 'computes exact even-count medians and preserves fractional allocation medians' do
      expect(WoodsABCompare::Reporter.median([100, 300])).to eq(200.0)
      expect(WoodsABCompare::Reporter.median([100, 101])).to eq(100.5)
      expect(WoodsABCompare::Reporter.median([10, 50, 20])).to eq(20)
      expect(WoodsABCompare::Reporter.format_alloc(100.5)).to eq('100.5')
      expect(WoodsABCompare::Reporter.format_alloc(200.0)).to eq('200')
    end

    it 'flags fingerprint drift in later candidate or base pairs and missing fingerprints' do
      good = { 'fixture_fingerprints' => { 'a' => '111' } }
      drifted = { 'fixture_fingerprints' => { 'a' => '999' } }
      missing = { 'fixture_fingerprints' => {} }

      expect(WoodsABCompare::Reporter.verify_fingerprints([good, good], [good, good])).to eq([])

      cand_drift = WoodsABCompare::Reporter.verify_fingerprints([good, good], [good, drifted])
      expect(cand_drift).to include(a_string_matching(/candidate pair 2: drift in a/))

      base_drift = WoodsABCompare::Reporter.verify_fingerprints([good, drifted], [good, good])
      expect(base_drift).to include(a_string_matching(/base pair 2: drift in a/))

      missing_err = WoodsABCompare::Reporter.verify_fingerprints([good, good], [good, missing])
      expect(missing_err).to include(a_string_matching(/candidate pair 2: missing or empty/))
    end

    it 'rejects mid-run worktree revision or cleanliness changes' do
      before_meta = { dir: '/tmp/wt', sha: 'a' * 40, clean: true }
      changed_sha = { dir: '/tmp/wt', sha: 'b' * 40, clean: true }
      became_dirty = { dir: '/tmp/wt', sha: 'a' * 40, clean: false }

      expect { WoodsABCompare.verify_unchanged!(before_meta, before_meta) }.not_to raise_error
      expect { WoodsABCompare.verify_unchanged!(before_meta, changed_sha) }
        .to raise_error(RuntimeError, /changed during sampling/)
      expect { WoodsABCompare.verify_unchanged!(before_meta, became_dirty) }
        .to raise_error(RuntimeError, /changed during sampling/)
    end

    it 'rejects partial SearchResults even when scanned_units matches and accepts exhausted complete scans' do
      unreadable = Woods::MCP::SearchResults.new(limit: 20).tap { |r| r.stop('unreadable_or_corrupt_source') }.response
                                            .merge(scan: { scanned_units: 400 })
      budgeted = Woods::MCP::SearchResults.new(limit: 20).tap { |r| r.stop('byte_budget') }.response
                                          .merge(scan: { scanned_units: 400 })
      complete = Woods::MCP::SearchResults.new(limit: 20).finish.response
                                          .merge(scan: { scanned_units: 400 })

      expect { WoodsABCompare::Reporter.verify_complete_search!(unreadable, expected_units: 400) }
        .to raise_error(RuntimeError, /incomplete.*unreadable_or_corrupt_source/)
      expect { WoodsABCompare::Reporter.verify_complete_search!(budgeted, expected_units: 400) }
        .to raise_error(RuntimeError, /incomplete.*byte_budget/)
      expect { WoodsABCompare::Reporter.verify_complete_search!(complete, expected_units: 400) }
        .not_to raise_error
    end

    it 'isolates git provenance queries from inherited GIT_DIR and GIT_WORK_TREE' do
      repo_root = File.expand_path('../..', __dir__)
      saved = %w[GIT_DIR GIT_WORK_TREE].to_h { |k| [k, ENV.fetch(k, nil)] }
      ENV['GIT_DIR'] = '/nonexistent/woods-git-dir'
      ENV['GIT_WORK_TREE'] = '/nonexistent/woods-work-tree'

      meta = WoodsABCompare::Provenance.git_meta!(repo_root)
      expect(meta[:sha]).to match(/\A[0-9a-f]{40}\z/)
    ensure
      saved.each { |k, v| ENV[k] = v }
    end
  end

  describe 'WoodsEndToEndProfile fingerprint helpers' do
    it 'normalizes generated_at in flow delta fingerprints while detecting real step changes' do
      Dir.mktmpdir('flow_delta_fp') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'flows'))
        unit = Struct.new(:identifier).new('Ctrl0Controller')
        File.write(File.join(dir, 'flows', 'flow_index.json'),
                   JSON.generate('Ctrl0Controller#act_0' => 'flows/Ctrl0Controller_act_0.json'))

        base_doc = { 'entry_point' => 'Ctrl0Controller#act_0', 'generated_at' => '2026-11-23T12:00:00Z',
                     'steps' => [{ 'unit' => 'Service0', 'operations' => [{ 'target' => 'OldGw' }] }] }
        File.write(File.join(dir, 'flows', 'Ctrl0Controller_act_0.json'), JSON.generate(base_doc))
        first = WoodsEndToEndProfile::GraphAndFlowBench.fingerprint_flow_delta(dir, [unit], { 'Ctrl0Controller' => {} })

        same_semantic = base_doc.merge('generated_at' => '2026-11-23T12:00:05Z')
        File.write(File.join(dir, 'flows', 'Ctrl0Controller_act_0.json'), JSON.generate(same_semantic))
        second = WoodsEndToEndProfile::GraphAndFlowBench.fingerprint_flow_delta(dir, [unit],
                                                                                { 'Ctrl0Controller' => {} })
        expect(second).to eq(first)

        changed_step = base_doc.merge('steps' => [{ 'unit' => 'Service0', 'operations' => [{ 'target' => 'NewGw' }] }])
        File.write(File.join(dir, 'flows', 'Ctrl0Controller_act_0.json'), JSON.generate(changed_step))
        third = WoodsEndToEndProfile::GraphAndFlowBench.fingerprint_flow_delta(dir, [unit], { 'Ctrl0Controller' => {} })
        expect(third).not_to eq(first)
      end
    end

    it 'fails closed when the expected edited unit payload or source_code is missing' do
      Dir.mktmpdir('edited_source_fp') do |payload|
        expect { WoodsEndToEndProfile::IndexFingerprint.edited_service_source(payload) }
          .to raise_error(RuntimeError, /Missing expected edited unit payload/)

        id = 'Billing::Processor0Service'
        path = File.join(payload, 'services', "Billing__Processor0Service_#{Digest::SHA256.hexdigest(id)[0, 8]}.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate('identifier' => id, 'source_code' => nil))
        expect { WoodsEndToEndProfile::IndexFingerprint.edited_service_source(payload) }
          .to raise_error(RuntimeError, /Missing source_code/)

        File.write(path, JSON.generate('identifier' => id, 'source_code' => 'class Processor0Service; end'))
        expect(WoodsEndToEndProfile::IndexFingerprint.edited_service_source(payload))
          .to eq('class Processor0Service; end')
      end
    end
  end

  describe 'script/profile-compare' do
    let(:raw_receipt) do
      {
        'operation' => 'full',
        'total' => { 'wall_ms' => 100.0, 'cpu_ms' => 80.0, 'allocations' => 10_000 },
        'phases' => [{ 'name' => 'extraction', 'wall_ms' => 50.0, 'cpu_ms' => 45.0, 'allocations' => 5_000 }]
      }
    end

    def synthetic_receipt(incremental_matches: true, include_rebuild_key: true, digest: 'abc123')
      metric = { 'wall_ms' => 10.0, 'cpu_ms' => 8.0, 'allocations' => 1000 }
      sub = { 'median_wall_ms' => 5.0, 'median_cpu_ms' => 4.0, 'median_allocations' => 500 }
      receipt = {
        'git_sha' => 'a' * 40,
        'full_extraction' => { 'total' => metric, 'phases' => [] },
        'incremental_noop' => { 'total' => metric, 'phases' => [] },
        'incremental_method_edit' => { 'total' => metric, 'phases' => [] },
        'graph_analyzer' => { 'analyze' => sub, 'cycles' => sub, 'bridges' => sub },
        'flow_precomputer' => { 'precompute' => sub, 'recompute_delta' => sub },
        'reader_and_lexical' => {
          'edges_via' => sub, 'dependents_via' => sub, 'deep_search' => sub,
          'lexical_build' => sub, 'lexical_query' => sub
        },
        'fixture_fingerprints' => { 'full_index_digest' => digest }
      }
      receipt['incremental_matches_clean_rebuild'] = incremental_matches if include_rebuild_key
      receipt
    end

    it 'rejects mixed raw and synthetic receipts before calculating deltas' do
      Dir.mktmpdir('profile_compare_spec') do |dir|
        base_path = File.join(dir, 'raw.json')
        cand_path = File.join(dir, 'synthetic.json')
        File.write(base_path, JSON.generate(raw_receipt))
        File.write(cand_path, JSON.generate(synthetic_receipt))

        _out, err, status = Open3.capture3(RbConfig.ruby, compare_script, base_path, cand_path)
        expect(status.exitstatus).to eq(2)
        expect(err).to include('baseline=raw_profile', 'candidate=synthetic_suite')
      end
    end

    it 'rejects internal incremental_matches_clean_rebuild failure even when both receipts match' do
      Dir.mktmpdir('profile_compare_spec') do |dir|
        base_path = File.join(dir, 'base.json')
        cand_path = File.join(dir, 'cand.json')
        File.write(base_path, JSON.generate(synthetic_receipt(incremental_matches: false)))
        File.write(cand_path, JSON.generate(synthetic_receipt(incremental_matches: false)))

        out, _err, status = Open3.capture3(RbConfig.ruby, compare_script, base_path, cand_path)
        expect(status.exitstatus).to eq(1)
        expect(out).to include('Fixture fingerprints: DRIFT')
        expect(out).to include('baseline incremental_matches_clean_rebuild is false')
        expect(out).to include('candidate incremental_matches_clean_rebuild is false')
      end
    end

    it 'rejects synthetic receipts with omitted, nil, or non-boolean incremental_matches_clean_rebuild' do
      Dir.mktmpdir('profile_compare_spec') do |dir|
        base_path = File.join(dir, 'base.json')
        cand_path = File.join(dir, 'cand.json')
        File.write(base_path, JSON.generate(synthetic_receipt(include_rebuild_key: false)))
        File.write(cand_path, JSON.generate(synthetic_receipt(incremental_matches: 'true')))

        out, _err, status = Open3.capture3(RbConfig.ruby, compare_script, base_path, cand_path)
        expect(status.exitstatus).to eq(1)
        expect(out).to include('Fixture fingerprints: DRIFT')
        expect(out).to include('baseline incremental_matches_clean_rebuild is missing or unverified')
        expect(out).to include('candidate incremental_matches_clean_rebuild is missing or unverified')
      end
    end

    it 'passes when both synthetic receipts match with explicit true incremental_matches_clean_rebuild' do
      Dir.mktmpdir('profile_compare_spec') do |dir|
        base_path = File.join(dir, 'base.json')
        cand_path = File.join(dir, 'cand.json')
        File.write(base_path, JSON.generate(synthetic_receipt(incremental_matches: true)))
        File.write(cand_path, JSON.generate(synthetic_receipt(incremental_matches: true)))

        out, _err, status = Open3.capture3(RbConfig.ruby, compare_script, base_path, cand_path)
        expect(status.exitstatus).to eq(0)
        expect(out).to include('Fixture fingerprints: PASS')
      end
    end

    it 'reports Fixture fingerprints: N/A for raw-to-raw timing receipts' do
      Dir.mktmpdir('profile_compare_spec') do |dir|
        base_path = File.join(dir, 'raw1.json')
        cand_path = File.join(dir, 'raw2.json')
        File.write(base_path, JSON.generate(raw_receipt))
        File.write(cand_path, JSON.generate(raw_receipt))

        out, _err, status = Open3.capture3(RbConfig.ruby, compare_script, base_path, cand_path)
        expect(status.exitstatus).to eq(0)
        expect(out).to include('Fixture fingerprints: N/A')
      end
    end
  end
end
