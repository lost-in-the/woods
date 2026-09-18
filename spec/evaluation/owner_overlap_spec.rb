# frozen_string_literal: true

require 'spec_helper'
require_relative '../../bench/evaluation/owner_overlap_cases'

RSpec.describe OwnerOverlap do
  let(:fixtures) { OwnerOverlap::Cases.all.to_h { |fixture| [fixture.fetch(:name), fixture] } }

  def run_case(name, policy: true, **options)
    OwnerOverlap::Cases.run(fixtures.fetch(name), policy: policy, **options)
  end

  it 'retains another necessary owner after a complete class already delivered overlapping methods' do
    baseline = run_case('crowded_overlap', policy: false)
    candidate = run_case('crowded_overlap')
    expect(baseline[:necessary_method_recall]).to eq(0.5)
    expect(candidate[:necessary_method_recall]).to eq(1.0)
    expect(baseline[:executable_fixture_pass]).to be(false)
    expect(candidate[:executable_fixture_pass]).to be(true)
    expect(candidate[:sources].first).to eq(baseline[:sources].first)
    expect(candidate[:trace].map { |row| row[:reason] }).to include('complement_before_covered_span')
  end

  %w[single_owner exact_target pinpoint disjoint_methods inlined_concern_unknown truncated_parent].each do |name|
    it "preserves the baseline context for #{name}" do
      expect(run_case(name)[:context]).to eq(run_case(name, policy: false)[:context])
    end
  end

  it 'retains the failed truncated-parent case and never pretends its methods were delivered' do
    result = run_case('truncated_parent')
    expect(result[:necessary_method_recall]).to eq(0.0)
    expect(result[:sources].first[:truncated]).to be(true)
    expect(result[:trace].drop(1).map { |row| row[:reason] }.uniq).to eq(['section_budget_exhausted'])
  end

  it 'uses verified byte origins on actual static Woods sources without asserting Rails runtime evidence' do
    fixture = OwnerOverlap::Cases.real_source
    baseline = OwnerOverlap::Cases.run(fixture, policy: false)
    candidate = OwnerOverlap::Cases.run(fixture, policy: true)
    expect(baseline[:necessary_method_recall]).to eq(0.5)
    expect(candidate[:necessary_method_recall]).to eq(1.0)
    expect(candidate[:trace].first[:origin][:path]).to eq('lib/woods/storage_identity.rb')
  end

  it 'is deterministic for equal scores and preserves the strongest original result' do
    results = Array.new(2) { run_case('crowded_overlap', equal_scores: true) }
    expect(results.first).to eq(results.last)
    expect(results.first[:sources].first[:identifier]).to eq('Invoice')
    expect(results.first[:sources].map { |source| source[:score] }.uniq).to eq([1.0])
  end

  it 'preserves exact baseline bytes when physical origin is unavailable' do
    empty = OwnerOverlap::Origins.new({})
    expect(run_case('crowded_overlap',
                    origins: empty)[:context]).to eq(run_case('crowded_overlap', policy: false)[:context])
  end

  it 'does not merge typed identities that share an identifier and path' do
    fixture = fixtures.fetch('crowded_overlap')
    duplicate = fixture[:units].first.merge(type: :model)
    fixture = fixture.merge(units: [fixture[:units].first, duplicate, fixture[:units].last], budget: 1000)
    result = OwnerOverlap::Cases.run(fixture, policy: true)
    invoice = result[:sources].select { |source| source[:identifier] == 'Invoice' }
    expect(invoice.map { |source| source[:type].to_s }).to contain_exactly('ruby_class', 'model')
  end

  it 'leaves all selected source identities and scores unchanged' do
    result = run_case('crowded_overlap')
    result[:sources].each do |source|
      trace = result[:trace].find do |row|
        Woods::StorageIdentity.identifier(row[:identifier]) == source[:identifier] && row[:type] == source[:type]
      end
      expect(trace[:score]).to eq(source[:score])
    end
  end

  it 'uses the existing framework and primary section allocations without borrowing' do
    fixture = fixtures.fetch('crowded_overlap')
    classification = fixture[:classification].dup
    classification.framework_context = true
    units = fixture[:units].map.with_index { |unit, index| index == 13 ? unit.merge(type: :rails_source) : unit }
    result = OwnerOverlap::Cases.run(fixture.merge(units: units, classification: classification), policy: true)
    expect(result[:trace].select { |row| row[:section] == :framework }.map { |row| row[:budget] }.uniq).to eq([46])
    expect(result[:trace].select { |row| row[:section] == :primary }.map { |row| row[:budget] }.uniq).to eq([183])
  end

  it 'does not promote a known owner across an unknown-origin candidate' do
    fixture = fixtures.fetch('crowded_overlap')
    units = fixture[:units].map.with_index do |unit, index|
      index == 1 ? unit.merge(source_code: unit[:source_code] + "# synthesized display\n") : unit
    end
    modified = fixture.merge(units: units)
    candidate = OwnerOverlap::Cases.run(modified, policy: true)
    baseline = OwnerOverlap::Cases.run(modified, policy: false)
    expect(candidate[:sources].first(2)).to eq(baseline[:sources].first(2))
    expect(candidate[:trace][1][:reason]).to eq('unknown_origin')
  end

  it 'preserves supporting budget and never uses primary overlap to omit supporting evidence' do
    fixture = fixtures.fetch('crowded_overlap')
    candidate_sources = { 'Invoice#step_1' => :graph_expansion }
    result = OwnerOverlap::Cases.run(fixture.merge(candidate_sources: candidate_sources), policy: true)
    primary = result[:trace].select { |row| row[:section] == :primary }
    supporting = result[:trace].select { |row| row[:section] == :supporting }
    expect(primary.map { |row| row[:budget] }.uniq).to eq([149])
    expect(supporting.map { |row| row[:budget] }.uniq).to eq([80])
    expect(supporting.first).to include(admitted: true, reason: 'single_owner_bypass')
  end

  it 'reports estimated output tokens consistently and stays within these fixed budgets' do
    fixtures.each_value do |fixture|
      [false, true].each do |policy|
        result = OwnerOverlap::Cases.run(fixture, policy: policy)
        expect(result[:estimated_context_tokens]).to eq((result[:context].length / 4.0).ceil)
        expect(result[:estimated_context_tokens]).to be <= result[:budget]
      end
    end
  end

  describe OwnerOverlap::Origins do
    it 'uses exact original UTF-8 byte offsets and copied snapshots' do
      source = +"# café\nclass Invoice; end\n"
      registry = described_class.new('/invoice.rb' => source)
      source.replace('changed')
      origin = registry.for(file_path: '/invoice.rb', source_code: 'class Invoice; end')
      expect(origin).to include(start_byte: 8, end_byte: 26)
    end

    it 'refuses ambiguous duplicate source text and synthesized concern display' do
      registry = described_class.new('/invoice.rb' => "def call; end\ndef call; end\n")
      expect(registry.for(file_path: '/invoice.rb', source_code: 'def call; end')).to be_nil
      expect(registry.for(file_path: '/invoice.rb', source_code: '# Included from: Chargeable')).to be_nil
    end
  end
end

RSpec.describe 'Owner overlap capture' do
  let(:root) { File.expand_path('../../bench/evaluation', __dir__) }
  let(:capture) { JSON.parse(File.read(File.join(root, 'owner_overlap_capture.json'))) }

  it 'keeps all 28 original questions, labels, budgets and full contexts unchanged' do
    corpus = JSON.parse(File.read(File.join(root, 'corpus.json')))
    prior = JSON.parse(File.read(File.join(root, 'evidence_comparison_capture.json')))
    controls = capture.fetch('results').select { |row| row['fixture_kind'] == 'Canopy_unknown_origin' }
    expect(controls.size).to eq(56)
    controls.each do |row|
      query = corpus.fetch('queries').find { |entry| entry['id'] == row['id'] }
      previous = prior.fetch('results').find do |entry|
        entry['id'] == row['id'] && entry['condition'] == 'semantic_full'
      end
      expect(row.fetch('expected')).to eq(query.fetch('expected_units'))
      expect(row.fetch('budget')).to eq(query.fetch('budget'))
      expect(row.fetch('context_sha256')).to eq(previous.fetch('context_sha256'))
      expect(row.fetch('actual_context_tokens_cl100k')).to eq(previous.fetch('actual_context_tokens_cl100k'))
    end
  end

  it 'binds the static source fixture to the actual captured Woods bytes' do
    fixture = OwnerOverlap::Cases.real_source
    digests = fixture[:sources].transform_values { |source| Digest::SHA256.hexdigest(source) }
    expect(capture.fetch('source_snapshots').fetch(fixture[:name])).to eq(digests)
  end

  it 'retains all fixed conditions including failed and unmeasured task outcomes' do
    fixtures = capture.fetch('results').reject { |row| row['fixture_kind'] == 'Canopy_unknown_origin' }
    expect(fixtures.size).to eq(16)
    expect(fixtures.map { |row| row.fetch('executable_fixture_pass') }.uniq).to contain_exactly(true, false, nil)
    expect(capture.fetch('fixed_case_gold').size).to eq(8)
  end
end
