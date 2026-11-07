# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/change_set'
require 'woods/source_references/collector'
require 'woods/extraction/hybrid_rerun_policy'

# A Ruby edit refreshes a hybrid family whole only when a changed file could
# have changed what one of its units' constants means. The baseline is the
# published source-reference cache: owners by type and path, and the
# collector's analysis of every analysed source.
RSpec.describe Woods::Extraction::HybridRerunPolicy do
  let(:root) { Dir.mktmpdir('woods-hybrid-rerun') }
  let(:collector) { Woods::SourceReferences::Collector.new }
  let(:job_source) do
    "module Billing\n  class PayJob < ApplicationJob\n    queue_as Settings::QUEUE\n    " \
      "def perform(id) = Invoice.find(id)\n  end\nend\n"
  end
  let(:sources) do
    { 'app/jobs/billing/pay_job.rb' => job_source,
      'app/models/billing/settings.rb' => "module Billing\n  class Settings\n    QUEUE = 'billing'\n  end\nend\n",
      'app/models/invoice.rb' => "class Invoice < ApplicationRecord\nend\n",
      'app/models/widget.rb' => "class Widget < ApplicationRecord\nend\n" }
  end
  let(:owners) do
    [{ 'type' => 'job', 'identifier' => 'Billing::PayJob', 'file_path' => 'app/jobs/billing/pay_job.rb',
       'added' => [] }]
  end
  let(:baseline) do
    files = sources.to_h { |path, source| [path, { 'identity' => path, 'analysis' => collector.call(source) }] }
    { 'version' => 1, 'callers' => {}, 'files' => files, 'owners' => owners }
  end
  let(:policy) { described_class.new(baseline: baseline, root: root, collector: collector) }

  before { sources.each { |path, source| write(path, source) } }
  after { FileUtils.rm_rf(root) }

  def write(path, source)
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, source)
  end

  let(:job_sources) { ['app/jobs/billing/pay_job.rb'] }

  def decide(*paths, baseline: self.baseline, sources: job_sources, new_classes: [])
    described_class.new(baseline: baseline, root: root, collector: collector)
                   .decide(:jobs, change_set: Woods::ChangeSet.new(paths: paths, root: root),
                                  sources: sources, new_classes: new_classes)
  end

  it 'refreshes whole without a baseline' do
    expect(decide('app/models/widget.rb',
                  baseline: nil)).to have_attributes(wholesale?: true, reason: /no source-reference baseline/)
  end

  it 're-extracts narrowly when no changed file declares a constant a unit names' do
    write('app/models/widget.rb', "class Widget < ApplicationRecord\n  def label = name\nend\n")
    decision = decide('app/models/widget.rb')

    expect(decision.wholesale?).to be(false)
    expect(decision.reason).to include('blast radius')
  end

  it 'refreshes whole when a changed file declares a constant a unit names through its lexical nesting' do
    write('app/models/billing/settings.rb', "module Billing\n  class Settings\n    QUEUE = 'urgent'\n  end\nend\n")
    expect(decide('app/models/billing/settings.rb'))
      .to have_attributes(wholesale?: true, reason: /declares Billing::Settings/)
  end

  it 'refreshes whole when a changed file declares a constant a unit names in full' do
    expect(decide('app/models/invoice.rb')).to have_attributes(wholesale?: true, reason: /declares Invoice/)
  end

  it 'refreshes whole when a changed file newly declares a constant a unit names' do
    write('app/models/widget.rb', "class Widget < ApplicationRecord\nend\nmodule Settings\n  QUEUE = 'late'\nend\n")
    expect(decide('app/models/widget.rb')).to have_attributes(wholesale?: true, reason: /declares Settings/)
  end

  it 'refreshes whole when a changed file used to declare a constant a unit names' do
    write('app/models/invoice.rb', "class Receipt < ApplicationRecord\nend\n")
    expect(decide('app/models/invoice.rb')).to have_attributes(wholesale?: true, reason: /declares Invoice/)
  end

  it 'refreshes whole when a changed file defines by a construct the collector cannot see' do
    write('app/models/widget.rb', "class Widget < ApplicationRecord\n  Object.const_set(:QUEUE, 'x')\nend\n")
    expect(decide('app/models/widget.rb')).to have_attributes(wholesale?: true, reason: /defines by const_set/)
  end

  it 'refreshes whole when a changed file is a source of one of its units, present or deleted' do
    expect(decide('app/jobs/billing/pay_job.rb')).to have_attributes(wholesale?: true, reason: /one of its own/)
    File.delete(File.join(root, 'app/jobs/billing/pay_job.rb'))
    expect(decide('app/jobs/billing/pay_job.rb')).to have_attributes(wholesale?: true, reason: /one of its own/)
  end

  it 'refreshes whole when runtime discovery disagrees with the graph, or is incomplete' do
    expect(decide('app/models/widget.rb', new_classes: ['Billing::NightlyJob']))
      .to have_attributes(wholesale?: true, reason: /runtime discovery of Billing::NightlyJob differs/)
    expect(decide('app/models/widget.rb', new_classes: nil))
      .to have_attributes(wholesale?: true, reason: /discovery is incomplete/)
  end

  it 'refreshes whole when a unit source was never analysed' do
    baseline['files'].delete('app/jobs/billing/pay_job.rb')
    expect(decide('app/models/widget.rb')).to have_attributes(wholesale?: true, reason: /never analysed/)
  end

  it 'refreshes whole when a changed file does not parse' do
    write('app/models/widget.rb', "class Widget <\n")
    expect(decide('app/models/widget.rb')).to have_attributes(wholesale?: true, reason: /does not parse/)
  end

  it 'answers for the sources it is given, not for every family' do
    changes = Woods::ChangeSet.new(paths: ['app/models/invoice.rb'], root: root)
    decision = policy.decide(:serializers, change_set: changes, sources: [], new_classes: [])
    expect(decision.wholesale?).to be(false)
  end
end
