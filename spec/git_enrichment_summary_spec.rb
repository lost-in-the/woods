# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/dependency_graph'
require 'woods/extracted_unit'
require 'woods/git_enrichment_summary'

RSpec.describe Woods::GitEnrichmentSummary do
  let(:root) { Dir.mktmpdir('woods_git_summary') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:head) { 'a' * 40 }
  let(:healthy) { { available: true, reason: nil } }

  after { FileUtils.rm_rf(root) }

  def source(relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# #{relative}\n")
    path
  end

  def register(identifier, type: :service, file: nil, commits: nil)
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: file)
    unit.metadata[:git] = { commit_count: commits, change_frequency: :new } unless commits.nil?
    graph.register(unit)
    unit
  end

  def summarize(availability: healthy, refreshed: :all, head_sha: head)
    described_class.build(graph: graph, root: root, availability: availability, refreshed: refreshed,
                          head_sha: head_sha)
  end

  describe '.build' do
    it 'is available when every eligible unit carries facts' do
      register('A', file: source('app/services/a.rb'), commits: 3)
      register('B', file: source('app/services/b.rb'), commits: 1)

      expect(summarize).to include(
        'version' => 1, 'state' => 'available', 'reason' => nil, 'head_sha' => head,
        'coverage' => { 'eligible_units' => 2, 'with_facts' => 2, 'history_unavailable' => 0,
                        'excluded' => { 'fileless' => 0, 'dependency_owned' => 0, 'source_missing' => 0 } },
        'capture' => { 'refreshed' => 2, 'retained' => 0 }
      )
    end

    it 'counts a successfully observed zero-commit history as facts, not as a failure' do
      register('Fresh', file: source('app/services/fresh.rb'), commits: 0)

      expect(summarize).to include('state' => 'available')
      expect(summarize.fetch('coverage')).to include('with_facts' => 1, 'history_unavailable' => 0)
    end

    it 'names fileless, dependency-owned and vanished-source units as expected exclusions' do
      register('Routes', type: :route)
      register('rails/activerecord', type: :rails_source, file: source('vendor/ar.rb'))
      register('Vendored', file: source('vendor/bundle/v.rb'))
      register('Gone', file: File.join(root, 'app/services/gone.rb'))
      register('A', file: source('app/services/a.rb'), commits: 2)

      expect(summarize.fetch('coverage')).to eq(
        'eligible_units' => 1, 'with_facts' => 1, 'history_unavailable' => 0,
        'excluded' => { 'fileless' => 1, 'dependency_owned' => 2, 'source_missing' => 1 }
      )
    end

    it 'counts typed identities, so one identifier under two types is two units' do
      register('reports', type: :database_view, file: source('db/views/reports_v01.sql'), commits: 1)
      register('reports', type: :factory, file: source('spec/factories/reports.rb'), commits: 4)

      expect(summarize.fetch('coverage')).to include('eligible_units' => 2, 'with_facts' => 2)
    end

    it 'counts a multi-source unit once, with facts when at least one source has history' do
      unit = Woods::ExtractedUnit.new(type: :lib, identifier: 'Bundle', file_path: source('lib/a.rb'))
      graph.register(unit)
      graph.annotate('Bundle', type: :lib, source_paths: [source('lib/a.rb'), source('lib/b.rb')], git_sources: 1)

      expect(summarize.fetch('coverage')).to include('eligible_units' => 1, 'with_facts' => 1)
    end

    it 'is unavailable with a stable reason when git failed and no unit carries facts' do
      register('A', file: source('app/services/a.rb'))

      result = summarize(availability: { available: false, reason: 'head_unresolvable' }, head_sha: nil)

      expect(result).to include('state' => 'unavailable', 'reason' => 'head_unresolvable', 'head_sha' => nil)
      expect(result.fetch('coverage')).to include('eligible_units' => 1, 'with_facts' => 0, 'history_unavailable' => 1)
    end

    it 'is degraded when git failed but earlier facts are retained, and says so' do
      register('Kept', file: source('app/services/kept.rb'), commits: 7)
      register('Rewritten', file: source('app/services/rewritten.rb'))

      result = summarize(availability: { available: false, reason: 'head_unresolvable' }, refreshed: Set.new,
                         head_sha: nil)

      expect(result).to include('state' => 'degraded', 'reason' => 'head_unresolvable')
      expect(result.fetch('coverage')).to include('with_facts' => 1, 'history_unavailable' => 1)
      expect(result.fetch('capture')).to eq('refreshed' => 0, 'retained' => 1)
    end

    it 'separates facts refreshed in this publication from retained ones' do
      register('New', file: source('app/services/new.rb'), commits: 1)
      register('Old', file: source('app/services/old.rb'), commits: 9)

      result = summarize(refreshed: Set.new([%w[New service]]))

      expect(result.fetch('capture')).to eq('refreshed' => 1, 'retained' => 1)
    end

    it 'is degraded, not available, when git works but a retained unit never had facts' do
      register('Kept', file: source('app/services/kept.rb'), commits: 1)
      register('Stranded', file: source('app/services/stranded.rb'))

      expect(summarize).to include('state' => 'degraded', 'reason' => 'units_missing_facts')
    end

    it 'is available for an application with nothing to enrich' do
      register('Routes', type: :route)

      expect(summarize).to include('state' => 'available', 'reason' => nil)
    end

    it 'stays bounded however many units there are' do
      40.times { |i| register("S#{i}", file: source("app/services/s#{i}.rb"), commits: 1) }

      expect(JSON.generate(summarize).bytesize).to be < 600
    end
  end

  describe '.from_manifest' do
    it 'passes a published summary through' do
      register('A', file: source('app/services/a.rb'), commits: 1)
      published = JSON.parse(JSON.generate(summarize))

      expect(described_class.from_manifest('git_enrichment' => published)).to eq(published)
    end

    it 'reports unknown, never healthy or zero, for a manifest written before the summary existed' do
      expect(described_class.from_manifest('counts' => { 'service' => 3 }))
        .to eq('state' => 'unknown', 'reason' => 'summary_missing')
    end

    it 'reports unknown for no manifest at all' do
      expect(described_class.from_manifest(nil)).to eq('state' => 'unknown', 'reason' => 'summary_missing')
    end

    it 'reports unknown for a summary of an unrecognised version' do
      expect(described_class.from_manifest('git_enrichment' => { 'version' => 99, 'state' => 'available' }))
        .to eq('state' => 'unknown', 'reason' => 'summary_version_unsupported')
    end
  end

  describe '.line' do
    it 'renders one task-summary line' do
      register('A', file: source('app/services/a.rb'), commits: 1)

      expect(described_class.line(summarize))
        .to eq('Git enrichment: available (1 of 1 eligible units with facts; 1 refreshed, 0 retained)')
    end

    it 'names the reason when not available' do
      register('A', file: source('app/services/a.rb'))
      summary = summarize(availability: { available: false, reason: 'shallow_repository' }, head_sha: nil)

      expect(described_class.line(summary))
        .to eq('Git enrichment: unavailable, shallow_repository ' \
               '(0 of 1 eligible units with facts; 0 refreshed, 0 retained)')
    end

    it 'says unknown for an older manifest' do
      expect(described_class.line('state' => 'unknown', 'reason' => 'summary_missing'))
        .to eq('Git enrichment: unknown (summary_missing)')
    end
  end
end
