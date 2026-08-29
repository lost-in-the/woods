# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/ast_source_extraction'

# Direct structural test for the mixin. ViaInvariantSpecHelper excludes
# ast_source_extraction.rb from its structural :via scan, and the controller /
# mailer extractor specs only reach it transitively through their own
# build_action_chunks, so the extraction seam itself had no first-party
# assertions.
RSpec.describe Woods::Extractors::AstSourceExtraction do
  # The rescue path logs through Rails; the default unit suite does not boot it.
  let(:rails_logger) { double('Logger', debug: nil) }

  before { stub_const('Rails', double('Rails', logger: rails_logger)) }

  let(:fixture_dir) { Dir.mktmpdir('woods_ast_source') }
  let(:fixture_path) { File.join(fixture_dir, 'sample_action.rb') }

  let(:fixture_source) do
    <<~RUBY
      class AstSourceExtractionSample
        def index
          'index body'
        end

        def show
          'show body'
        end
      end
    RUBY
  end

  # Write the fixture to disk (the mixin reads the file) and evaluate it with
  # that same filename, so the defined methods carry a real on-disk
  # source_location — which is what the mixin resolves through
  # instance_method(...).source_location.
  let(:sample_class) do
    File.write(fixture_path, fixture_source)
    Object.class_eval(fixture_source, fixture_path, 1)
    AstSourceExtractionSample
  end

  let(:host) do
    Class.new do
      include Woods::Extractors::AstSourceExtraction
    end.new
  end

  after do
    Object.send(:remove_const, :AstSourceExtractionSample) if defined?(AstSourceExtractionSample)
    FileUtils.rm_rf(fixture_dir)
  end

  # The mixin's method is private: host extractors call it from their own
  # build_action_chunks, which is how the neighboring specs reach it too.
  def extract(klass, action)
    host.send(:extract_action_source, klass, action)
  end

  it 'extracts the source of a defined action from its file' do
    source = extract(sample_class, :index)

    expect(source).to include('def index')
    expect(source).to include("'index body'")
    expect(source).not_to include('def show')
  end

  it 'accepts a string action name as well as a symbol' do
    expect(extract(sample_class, 'show')).to include('def show')
  end

  it 'returns nil when the action is not defined on the class' do
    expect(extract(sample_class, :destroy)).to be_nil
    expect(rails_logger).to have_received(:debug).with(/destroy/)
  end

  it 'returns nil when the method has no source location' do
    sample_class.class_eval { define_method(:dynamic) { 'built at runtime' } }

    expect(extract(sample_class, :dynamic)).to be_nil
  end

  it 'returns nil when the defining file has vanished' do
    sample_class
    File.delete(fixture_path)

    expect(extract(sample_class, :index)).to be_nil
  end

  it 'returns nil when the file no longer contains the method' do
    sample_class
    File.write(fixture_path, "class AstSourceExtractionSample\nend\n")

    expect(extract(sample_class, :index)).to be_nil
  end
end
