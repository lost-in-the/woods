# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'
require 'woods/source_references/collector'

RSpec.describe 'Units re-extracted when an edit moves what their references resolve to' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-reference-retarget') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  let(:extractor) { Woods::Extractor.new(output_dir: @root.join('index')) }
  let(:graph) { extractor.instance_variable_get(:@dependency_graph) }
  let(:published) { {} }
  let(:files) { {} }
  let(:owners) { [] }

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object, version: '8.0.0'))
    allow(extractor).to receive(:read_published_unit) { |id, type| published[[type, id]] }
    extractor.instance_variable_set(:@source_reference_baseline, { 'files' => files, 'owners' => owners })
    referrer('app/models/host.rb', 'Host', "class Host < ApplicationRecord\n  def run = PingJob.perform_later\nend\n")
    referrer('app/services/audit.rb', 'Audit', "class Audit\n  def run = Reports::Summary.call\nend\n")
  end

  # A unit of the preceding generation, with the reference evidence the
  # baseline cache holds for its file.
  def referrer(path, identifier, source, contributors: nil)
    files[path] = { 'analysis' => Woods::SourceReferences::Collector.new.call(source) }
    owners << { 'type' => 'model', 'identifier' => identifier, 'file_path' => path, 'added' => [],
                'file_paths' => contributors }.compact
  end

  def edit(path, source, before: nil, identifier: 'Edited')
    absolute = @root.join(path)
    absolute.dirname.mkpath
    absolute.write(source) if source
    if before
      unit = Woods::ExtractedUnit.new(type: :job, identifier: identifier, file_path: absolute.to_s)
      unit.source_code = before
      graph.register(unit)
      published[[:job, identifier]] = JSON.parse(JSON.generate(unit.to_h))
    end
    Woods::ChangeSet.new(paths: [absolute.to_s], root: @root)
  end

  def retargeted(change_set)
    extractor.send(:reference_retarget_ids, extractor.send(:render_scope, change_set))
  end

  it 'selects the unit naming a job that a new nested job can shadow' do
    changes = edit('app/jobs/host/ping_job.rb', "class Host::PingJob < ::PingJob\nend\n")

    expect(retargeted(changes)).to eq(['Host'])
  end

  it 'selects the unit naming the job when the nested job is removed' do
    changes = edit('app/jobs/host/ping_job.rb', nil, before: "class Host::PingJob < ::PingJob\nend\n",
                                                     identifier: 'Host::PingJob')

    expect(retargeted(changes)).to eq(['Host'])
  end

  it 'selects the unit whose qualified reference passes through a new namespace' do
    changes = edit('app/services/audit/reports.rb', "class Audit\n  module Reports; end\nend\n")

    expect(retargeted(changes)).to eq(['Audit'])
  end

  it 'selects every unit whose source inlines the file holding the reference' do
    referrer('app/models/concerns/pinging.rb', 'Pinging', "module Pinging\n  def ping = AlertJob.perform_later\nend\n")
    owners << { 'type' => 'model', 'identifier' => 'Pinned', 'file_path' => 'app/models/pinned.rb', 'added' => [],
                'file_paths' => ['app/models/pinned.rb', 'app/models/concerns/pinging.rb'] }
    changes = edit('app/jobs/alert_job.rb', "class AlertJob < ApplicationJob\nend\n")

    expect(retargeted(changes)).to contain_exactly('Pinging', 'Pinned')
  end

  it 'falls back to the constants an opaque file declares' do
    changes = edit('app/jobs/host/ping_job.rb', "class Host::PingJob < ::PingJob\nend\nHost.const_set(:Other, 1)\n")

    expect(retargeted(changes)).to eq(['Host'])
  end

  it 'selects nothing for an edit inside a method body' do
    changes = edit('app/jobs/ping_job.rb', "class PingJob < ApplicationJob\n  def perform = 2\nend\n",
                   before: "class PingJob < ApplicationJob\n  def perform = 1\nend\n", identifier: 'PingJob')

    expect(retargeted(changes)).to eq([])
  end

  it 'selects nothing when no reference names the new constant' do
    changes = edit('app/jobs/host/other_job.rb', "class Host::OtherJob < ApplicationJob\nend\n")

    expect(retargeted(changes)).to eq([])
  end

  it 'selects nothing without a baseline reference cache' do
    extractor.instance_variable_set(:@source_reference_baseline, nil)
    changes = edit('app/jobs/host/ping_job.rb', "class Host::PingJob < ::PingJob\nend\n")

    expect(retargeted(changes)).to eq([])
  end
end
