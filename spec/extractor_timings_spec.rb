# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'active_support'
require 'active_support/core_ext/time'
require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'woods'
require 'woods/extractor'
require 'woods/rake_helpers'

# Per-extractor wall time, collected by family during a run and published in
# the generation manifest as `extractor_timings` (LOS-130). A field run can
# then say which family pays for a slow extraction without a profiler.
RSpec.describe Woods::Extractor, 'extractor timings' do
  let(:tmpdir) { Dir.mktmpdir('woods_timings') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:output_dir) { File.join(tmpdir, 'output') }
  let(:extractor) { described_class.new(output_dir: output_dir) }
  let(:logged) { [] }
  let(:logger) do
    instance_double(Logger).tap do |log|
      allow(log).to receive(:info) { |message| logged << message.to_s }
      allow(log).to receive(:warn)
      allow(log).to receive(:error)
      allow(log).to receive(:debug)
    end
  end
  let(:fake_units) do
    user = Woods::ExtractedUnit.new(identifier: 'User', type: :model, file_path: '/app/models/user.rb')
    user.source_code = 'class User; end'
    { models: [user] }
  end

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(Rails).to receive(:version).and_return('7.1.0')
    allow(Time).to receive(:current).and_return(Time.new(2026, 1, 1))
    allow(extractor).to receive(:safe_eager_load!)
    allow(extractor).to receive(:git_available?).and_return(false)
    allow(Woods::AtomicFile).to receive(:sync_directory_tree).and_return(:syncfs)

    Woods::Extractor::EXTRACTORS.each do |type, klass|
      stubs = { extract_all: fake_units.fetch(type, []) }
      stubs[:package_roots] = [] if klass == Woods::Extractors::PackageExtractor
      allow(klass).to receive(:new).and_return(instance_double(klass, **stubs))
    end
    allow(Woods::ModelNameCache).to receive(:model_names).and_return([])
    allow(Woods::ModelNameCache).to receive(:model_names_regex).and_return(/(?!)/)
  end

  after do
    FileUtils.rm_rf(tmpdir)
    Woods.configuration = Woods::Configuration.new
    Woods::ModelNameCache.reset!
  end

  def published_manifest
    path = Woods::RakeHelpers.woods_payload_dir(output_dir).join('manifest.json')
    JSON.parse(Woods::AtomicFile.read(path))
  end

  def ran_families
    Woods::Extractor::EXTRACTORS.keys.reject { |key| extractor.send(:skip_by_configuration?, key) }.map(&:to_s).sort
  end

  it 'answers an empty hash before any run' do
    expect(extractor.extractor_timings).to eq({})
  end

  [false, true].each do |concurrent|
    it "publishes one timing per family after a #{concurrent ? 'concurrent' : 'sequential'} full extraction" do
      Woods.configure { |c| c.concurrent_extraction = concurrent }

      extractor.extract_all

      timings = published_manifest.fetch('extractor_timings')
      expect(timings.keys).to eq(ran_families)
      expect(timings.values).to all(be_a(Float).and(be >= 0))
      expect(timings.values).to all(satisfy('be rounded to three decimals') { |v| v == v.round(3) })
      expect(extractor.extractor_timings).to eq(timings)
    end
  end

  it 'keeps the existing per-extractor log lines unchanged' do
    Woods.configure { |c| c.concurrent_extraction = false }

    extractor.extract_all

    expect(logged).to include('[Woods] Extracted 1 models in 0.0s')
  end

  it 'accumulates the incremental choke point under the family that ran' do
    consumer = Object.new

    result = extractor.send(:checked_extraction, :routes, consumer) { :routes_result }
    extractor.send(:checked_extraction, :routes, consumer) { :again }

    expect(result).to eq(:routes_result)
    expect(extractor.extractor_timings.keys).to eq(['routes'])
  end
end
