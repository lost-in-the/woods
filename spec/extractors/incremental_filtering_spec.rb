# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

# Verify that incremental re-extraction (re_extract_unit) silently skips unit
# types that cannot be re-extracted from a single file. Per CLAUDE.md:
#   "route, middleware, engine, scheduled_job" — no per-file extraction method
#   StateMachineExtractor and FactoryExtractor — return arrays, not registered in FILE_BASED
#   EventExtractor — two-pass, no single-file extraction method
#
# These types are in TYPE_TO_EXTRACTOR_KEY and EXTRACTORS but are absent from
# both FILE_BASED and CLASS_BASED, so re_extract_unit reports "not re-extracted"
# and skips them. Whole-app re-runs for these types are driven separately, by
# trigger path, in Extractor#rerun_whole_app_extractors (#164).
#
# Types that DO have single-file support (FILE_BASED or CLASS_BASED) should
# reach the extractor dispatch — verified here with a lightweight double.

# Unit types that have no single-file extraction path and must be skipped
# during incremental re-extraction.
INCREMENTAL_UNSUPPORTED_TYPES = %i[
  route middleware engine scheduled_job state_machine factory event rails_source
].freeze

RSpec.describe Woods::Extractor, '#re_extract_unit filtering' do
  let(:tmpdir) { Dir.mktmpdir('woods_incremental_test') }
  let(:rails_root) { Pathname.new(tmpdir) }
  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, 'output')) }

  before do
    stub_const('Rails', double('Rails'))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double('Logger').as_null_object)
    # RailsSourceExtractor#initialize calls Rails.version at construction time
    allow(Rails).to receive(:version).and_return('7.2.0')
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Build a minimal registered graph node for a given type and unit_id.
  def register_node(type, unit_id, file_path: nil)
    fp = file_path || File.join(tmpdir, "#{unit_id.downcase}.rb")
    FileUtils.touch(fp) unless File.exist?(fp)

    graph = extractor.dependency_graph
    graph.instance_variable_get(:@nodes)[unit_id] = {
      type => {
        type: type,
        file_path: fp,
        namespace: nil
      }
    }
    graph.instance_variable_get(:@edges)[unit_id] = { type => [] }
    fp
  end

  describe 'unsupported types are silently skipped' do
    INCREMENTAL_UNSUPPORTED_TYPES.each do |type|
      it "reports no re-extraction and does not raise for type :#{type}" do
        unit_id = "Sample#{type.to_s.camelize}"
        register_node(type, unit_id)

        result = nil
        expect { result = extractor.send(:re_extract_unit, unit_id) }.not_to raise_error
        # A nil return means no unit was produced — the type was skipped
        expect(result).to be_nil
      end
    end
  end

  describe 'FILE_BASED types reach the extractor dispatch' do
    it 'calls the file-based extractor method for a :service unit' do
      # Stub EXTRACTORS so we can intercept the call without a real Rails app
      fake_extractor_instance = double('ServiceExtractor')
      fake_extractor_class    = double('ServiceExtractorClass', new: fake_extractor_instance)

      stub_const('Woods::Extractor::EXTRACTORS', {
                   services: fake_extractor_class
                 })

      allow(fake_extractor_instance).to receive(:extract_service_file).and_return(nil)

      register_node(:service, 'UserService')

      extractor.send(:re_extract_unit, 'UserService')

      expect(fake_extractor_instance).to have_received(:extract_service_file)
    end

    it 'calls the file-based extractor method for a :concern unit' do
      fake_extractor_instance = double('ConcernExtractor')
      fake_extractor_class    = double('ConcernExtractorClass', new: fake_extractor_instance)

      stub_const('Woods::Extractor::EXTRACTORS', {
                   concerns: fake_extractor_class
                 })

      allow(fake_extractor_instance).to receive(:extract_concern_file).and_return(nil)

      register_node(:concern, 'Auditable')

      extractor.send(:re_extract_unit, 'Auditable')

      expect(fake_extractor_instance).to have_received(:extract_concern_file)
    end
  end

  describe 'GraphQL types reach the extractor dispatch' do
    it 'calls extract_graphql_file for :graphql_type units' do
      fake_extractor_instance = double('GraphQLExtractor')
      fake_extractor_class    = double('GraphQLExtractorClass', new: fake_extractor_instance)

      stub_const('Woods::Extractor::EXTRACTORS', {
                   graphql: fake_extractor_class
                 })

      allow(fake_extractor_instance).to receive(:extract_graphql_file).and_return(nil)

      register_node(:graphql_type, 'UserType')

      extractor.send(:re_extract_unit, 'UserType')

      expect(fake_extractor_instance).to have_received(:extract_graphql_file)
    end
  end

  describe 'framework-prefixed units are skipped before type dispatch' do
    it 'skips units with rails/ prefix regardless of type' do
      result = extractor.send(:re_extract_unit, 'rails/active_record')
      expect(result).to be_nil
    end

    it 'skips units with gems/ prefix regardless of type' do
      result = extractor.send(:re_extract_unit, 'gems/devise')
      expect(result).to be_nil
    end
  end
end
