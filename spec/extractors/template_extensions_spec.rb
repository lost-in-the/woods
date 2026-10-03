# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/template_extensions'

RSpec.describe Woods::Extractors::TemplateExtensions do
  let(:engines) { Woods::Extractors::ViewTemplateExtractor::ENGINES.map(&:new) }

  it 'scans every extension a registered view engine handles' do
    engines.flat_map(&:extensions).each do |extension|
      expect(described_class::SCANNED).to include(a_string_ending_with(extension[/\.[^.]+\z/]))
    end
  end

  it 'scans only extensions a registered view engine handles' do
    described_class::SCANNED.each do |extension|
      expect(engines).to include(satisfy { |engine| engine.handles?("app/views/widgets/show#{extension}") })
    end
  end

  it 'detects Slim templates without scanning them' do
    expect(described_class::DETECTED).to eq([*described_class::SCANNED, '.slim'])
  end
end
