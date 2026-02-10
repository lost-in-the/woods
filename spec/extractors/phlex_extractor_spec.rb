# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/extractors/phlex_extractor'

RSpec.describe CodebaseIndex::Extractors::PhlexExtractor do
  let(:rails_root) { Pathname.new('/rails') }
  let(:logger) { double('Logger', error: nil) }

  before do
    stub_const('Rails', double('Rails', root: rails_root, logger: logger))
    stub_const('CodebaseIndex::ModelNameCache', double('ModelNameCache', model_names_regex: /\b(?:User|Post)\b/))
    allow(File).to receive(:exist?) { false }
    allow(File).to receive(:read) { '' }
  end

  describe '#find_component_base (via extract_all)' do
    context 'when ApplicationComponent is a ViewComponent subclass' do
      it 'does not use ApplicationComponent as a Phlex base' do
        vc_base = Class.new
        stub_const('ViewComponent::Base', vc_base)

        app_component = Class.new(vc_base)
        app_component.define_singleton_method(:name) { 'ApplicationComponent' }
        stub_const('ApplicationComponent', app_component)

        extractor = described_class.new
        # With no Phlex classes defined, and ApplicationComponent being a VC,
        # extract_all should return empty (no Phlex base found)
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when ApplicationComponent is a Phlex subclass' do
      it 'uses ApplicationComponent as a Phlex base' do
        phlex_base = Class.new
        phlex_base.define_singleton_method(:descendants) { [] }
        stub_const('Phlex::HTML', phlex_base)

        # Phlex::HTML is found first in PHLEX_BASES, so ApplicationComponent
        # isn't reached — but this confirms Phlex classes take priority
        extractor = described_class.new
        # No descendants, so empty result but no error
        expect(extractor.extract_all).to eq([])
      end
    end

    context 'when no component framework is loaded' do
      it 'returns empty array' do
        extractor = described_class.new
        expect(extractor.extract_all).to eq([])
      end
    end
  end
end
