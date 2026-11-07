# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractor'

RSpec.describe 'incremental runtime inputs' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-runtime-inputs') do |root|
      @root = Pathname.new(root)
      example.run
    end
  end

  before do
    stub_const('Rails', double('Rails', root: @root, logger: double('Logger').as_null_object))
  end

  let(:extractor) { Woods::Extractor.new(output_dir: @root.join('index')) }

  describe 'hybrid runtime refresh selection' do
    it 'refreshes hybrid and component families after changing a path outside app/' do
      changes = Woods::ChangeSet.new(paths: ['lib/runtime_settings.rb'], root: @root)
      expect(extractor.send(:hybrid_discovery_keys, changes, []))
        .to eq(Set[:jobs, :serializers, :components, :view_components])
    end

    it 'refreshes hybrid and component families for an unreadable app/ constant edit' do
      FileUtils.mkdir_p(@root.join('app/models'))
      File.write(@root.join('app/models/queue_settings.rb'), "Object.const_set(:QUEUE, 'critical')\n")
      changes = Woods::ChangeSet.new(paths: ['app/models/queue_settings.rb'], root: @root)
      expect(extractor.send(:hybrid_discovery_keys, changes, []))
        .to eq(Set[:jobs, :serializers, :components, :view_components])
    end

    it 'refreshes only the hybrid families after an app/ edit that touches no constant a render resolves' do
      FileUtils.mkdir_p(@root.join('app/models'))
      File.write(@root.join('app/models/queue_settings.rb'), "class QueueSettings\n  QUEUE = 'critical'\nend\n")
      changes = Woods::ChangeSet.new(paths: ['app/models/queue_settings.rb'], root: @root)
      expect(extractor.send(:hybrid_discovery_keys, changes, [])).to eq(Set[:jobs, :serializers])
    end

    context 'with a published source-reference baseline' do
      let(:collector) { Woods::SourceReferences::Collector.new }
      let(:job_source) { "class ReportJob < ApplicationJob\n  queue_as QueueSettings::QUEUE\nend\n" }
      let(:baseline) do
        { 'version' => 1, 'callers' => {},
          'files' => { 'app/jobs/report_job.rb' => { 'identity' => 'x', 'analysis' => collector.call(job_source) } },
          'owners' => [{ 'type' => 'job', 'identifier' => 'ReportJob', 'file_path' => 'app/jobs/report_job.rb',
                         'added' => [] }] }
      end

      before do
        FileUtils.mkdir_p(@root.join('app/models'))
        extractor.instance_variable_set(:@source_reference_baseline, baseline)
        job = Woods::ExtractedUnit.new(type: :job, identifier: 'ReportJob',
                                       file_path: @root.join('app/jobs/report_job.rb').to_s)
        extractor.dependency_graph.register(job)
        allow(extractor).to receive(:hybrid_inventory_delta).and_return([])
      end

      it 'refreshes a hybrid family whole when runtime discovery disagrees with the graph' do
        allow(extractor).to receive(:hybrid_inventory_delta).with(:jobs, anything).and_return(['NightlyJob'])
        allow(extractor).to receive(:hybrid_inventory_delta).with(:serializers, anything).and_return([])
        File.write(@root.join('app/models/widget.rb'), "class Widget\nend\n")
        changes = Woods::ChangeSet.new(paths: ['app/models/widget.rb'], root: @root)
        expect(extractor.send(:hybrid_discovery_keys, changes, [])).to eq(Set[:jobs])
      end

      it 'leaves a hybrid family to its blast radius when the edit declares nothing its units name' do
        File.write(@root.join('app/models/widget.rb'), "class Widget\n  def label = name\nend\n")
        changes = Woods::ChangeSet.new(paths: ['app/models/widget.rb'], root: @root)
        expect(extractor.send(:hybrid_discovery_keys, changes, [])).to be_empty
      end

      it 'refreshes a hybrid family whole when the edit declares a constant its units name' do
        File.write(@root.join('app/models/queue_settings.rb'), "class QueueSettings\n  QUEUE = 'critical'\nend\n")
        changes = Woods::ChangeSet.new(paths: ['app/models/queue_settings.rb'], root: @root)
        expect(extractor.send(:hybrid_discovery_keys, changes, [])).to eq(Set[:jobs])
      end

      it 'refreshes both families whole when the edit defines constants the collector cannot see' do
        File.write(@root.join('app/models/widget.rb'), "Object.const_set(:QUEUE, 'critical')\n")
        changes = Woods::ChangeSet.new(paths: ['app/models/widget.rb'], root: @root)
        expect(extractor.send(:hybrid_discovery_keys, changes, []))
          .to eq(Set[:jobs, :serializers, :components, :view_components])
      end
    end

    %w[
      app/components/shelf_component.html.erb
      app/components/shelf_component/shelf_component.html.haml
      app/components/shelf_component.html.slim
    ].each do |path|
      it "refreshes view components after changing the sidecar template #{path}" do
        FileUtils.mkdir_p(@root.join('app/components'))
        File.write(@root.join('app/components/shelf_component.rb'), "class ShelfComponent\nend\n")
        changes = Woods::ChangeSet.new(paths: [path], root: @root)

        expect(extractor.send(:hybrid_discovery_keys, changes, [])).to eq(Set[:view_components])
      end
    end

    %w[config/locales/en.yml app/views/posts/index.html.erb config/queue.yml].each do |path|
      it "keeps #{path} scoped to hybrid units already in its blast radius" do
        changes = Woods::ChangeSet.new(paths: [path], root: @root)
        job = Woods::ExtractedUnit.new(type: :job, identifier: 'NestedJob', file_path: 'app/models/container.rb')
        extractor.dependency_graph.register(job)
        expect(extractor.send(:hybrid_discovery_keys, changes, [])).to be_empty
        expect(extractor.send(:hybrid_discovery_keys, changes, ['NestedJob'])).to eq(Set[:jobs])
      end
    end
  end

  describe 'hybrid inventory delta' do
    let(:known) do
      [Woods::ExtractedUnit.new(type: :job, identifier: 'ReportJob',
                                file_path: @root.join('app/jobs/report_job.rb').to_s),
       Woods::ExtractedUnit.new(type: :job, identifier: 'NestedJob', file_path: 'app/models/container.rb')]
    end
    let(:consumer) { double('Consumer', discoverable_classes: [double('Klass', name: 'NightlyJob')]) }

    before do
      known.each { |unit| extractor.dependency_graph.register(unit) }
      extractor.instance_variable_set(:@incremental_extractors, { jobs: consumer })
    end

    it 'answers nothing after a partial eager load without consulting discovery' do
      extractor.instance_variable_set(:@eager_load_complete, false)
      expect(consumer).not_to receive(:discoverable_classes)
      expect(extractor.send(:hybrid_inventory_delta, :jobs, [:job])).to be_nil
    end

    it 'names the classes discovered but unknown and the class-discovered units no longer found' do
      extractor.instance_variable_set(:@eager_load_complete, true)
      expect(extractor.send(:hybrid_inventory_delta, :jobs, [:job])).to eq(%w[NestedJob NightlyJob])
    end
  end

  %w[db/schema.rb db/structure.sql config/application.rb config/initializers/runtime.rb].each do |path|
    it "refuses #{path} before preparing an incremental payload in an unverified runtime" do
      expect(extractor).not_to receive(:prepare_incremental_run)
      expect { extractor.extract_changed([@root.join(path).to_s, 'app/models/post.rb']) }
        .to raise_error(Woods::ExtractionError, /fresh.*woods:extract/)
    end
  end

  it 'refreshes BehavioralProfile through resolved configuration rather than the nominal source filename' do
    require 'woods/extractors/configuration_extractor'
    profiler = instance_double(Woods::Extractors::BehavioralProfile)
    profile = Woods::ExtractedUnit.new(type: :configuration, identifier: 'BehavioralProfile', file_path: nil)
    allow(Woods::Extractors::BehavioralProfile).to receive(:new).and_return(profiler)
    expect(profiler).to receive(:extract).and_return(profile)
    path = @root.join('config/application.rb')
    path.dirname.mkpath
    path.write('# resolved configuration lives in Rails.application.config')

    consumer = Woods::Extractors::ConfigurationExtractor.new
    result = extractor.send(:re_extracted_units, consumer, :configuration, 'BehavioralProfile', path.to_s,
                            :configurations)
    expect(Array(result).map(&:identifier)).to eq(['BehavioralProfile'])
  end

  %i[jobs serializers].each do |key|
    it "refuses ownership transfer for #{key} after incomplete eager loading" do
      type = key == :jobs ? :job : :serializer
      first = @root.join('first.rb')
      second = @root.join('second.rb')
      [first, second].each { |path| path.write('# source remains present') }
      old = Woods::ExtractedUnit.new(type: type, identifier: 'Outer::Nested', file_path: first.to_s)
      fresh = Woods::ExtractedUnit.new(type: type, identifier: 'Outer::Nested', file_path: second.to_s)
      extractor.dependency_graph.register(old)
      extractor.instance_variable_set(:@eager_load_complete, false)
      extractor.instance_variable_set(:@incremental_extractors, { key => double('Consumer', extract_all: [fresh]) })

      expect { extractor.send(:replace_type_wholesale, key, Set.new) }
        .to raise_error(Woods::ExtractionError, /same-type identifier collision/)
      expect(extractor.dependency_graph.node('Outer::Nested', type: type)[:file_path]).to eq(first.to_s)
    end

    it "does not remove #{key} missing from an incomplete runtime inventory" do
      type = key == :jobs ? :job : :serializer
      old = Woods::ExtractedUnit.new(type: type, identifier: 'Outer::Nested', file_path: 'app/models/outer.rb')
      extractor.dependency_graph.register(old)
      extractor.instance_variable_set(:@eager_load_complete, false)
      extractor.instance_variable_set(:@incremental_extractors, { key => double('Consumer', extract_all: []) })

      expect(extractor.send(:replace_type_wholesale, key, Set.new)).to be_empty
      expect(extractor.dependency_graph.node('Outer::Nested', type: type)).not_to be_nil
    end

    it "refuses partial #{key} output without replacing the old units" do
      type = key == :jobs ? :job : :serializer
      old = Woods::ExtractedUnit.new(type: type, identifier: 'Outer::Nested', file_path: 'app/models/outer.rb')
      consumer = double('PartialConsumer')
      allow(consumer).to receive(:extract_all) do
        Woods::SourceInputs::ConsumerErrors.record(consumer)
        []
      end
      extractor.dependency_graph.register(old)
      extractor.instance_variable_set(:@eager_load_complete, true)
      extractor.instance_variable_set(:@incremental_extractors, { key => consumer })
      expect(extractor.send(:replace_type_wholesale, key, Set.new)).to be_empty
      expect(extractor.dependency_graph.node('Outer::Nested', type: type)).not_to be_nil
      expect { extractor.send(:raise_on_handled_extraction_failure!) }.to raise_error(Woods::ExtractionError, /#{key}/)
    end
  end
end
