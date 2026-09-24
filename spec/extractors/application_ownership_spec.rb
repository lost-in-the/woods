# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/extractors/view_component_extractor'
require 'woods/extractors/phlex_extractor'
require 'woods/extractors/action_cable_extractor'

RSpec.describe 'Application component and channel ownership' do
  include_context 'extractor setup'

  {
    'ViewComponent::Base' => [Woods::Extractors::ViewComponentExtractor, :extract_component],
    'Phlex::HTML' => [Woods::Extractors::PhlexExtractor, :extract_component],
    'ActionCable::Channel::Base' => [Woods::Extractors::ActionCableExtractor, :extract_channel]
  }.each do |base_name, (extractor_class, method)|
    context "with #{base_name}" do
      let(:base) do
        Class.new.tap { |klass| klass.define_singleton_method(:descendants) { [] } }
      end
      let(:owned) { Class.new(base) }
      let(:foreign) { Class.new(base) }
      let(:unrelated) { Class.new }
      let(:extractor) { extractor_class.new }

      before do
        stub_const(base_name, base)
        stub_const('OwnedDefinition', owned)
        stub_const('ForeignDefinition', foreign)
        stub_const('WrongAncestry', unrelated)
        allow(base).to receive(:descendants).and_return([owned, foreign])
        owned_path = create_file('app/custom/owned_definition.rb', 'class OwnedDefinition; end')
        foreign_path = create_file('vendor/example/foreign_definition.rb', 'class ForeignDefinition; end')
        unrelated_path = create_file('app/custom/wrong_ancestry.rb', 'class WrongAncestry; end')
        allow(Object).to receive(:const_source_location).and_call_original
        { 'OwnedDefinition' => owned_path, 'ForeignDefinition' => foreign_path,
          'WrongAncestry' => unrelated_path }.each do |name, path|
          allow(Object).to receive(:const_source_location).with(name).and_return([path, 1])
        end
      end

      it 'discovers only an application-owned descendant, including methodless classes' do
        expect(extractor.discoverable_classes).to eq([owned])
      end

      it 'rejects an external definition through direct extraction' do
        expect(extractor.public_send(method, foreign)).to be_nil
      end

      it 'rejects application classes from a different runtime family through direct extraction' do
        expect(extractor.public_send(method, unrelated)).to be_nil
      end
    end
  end
end
