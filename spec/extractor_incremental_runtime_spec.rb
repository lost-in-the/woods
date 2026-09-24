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
