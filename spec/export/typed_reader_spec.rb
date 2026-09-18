# frozen_string_literal: true

require 'spec_helper'
require 'woods/export/typed_reader'

RSpec.describe Woods::Export::TypedReader do
  it 'refuses an injected reader that ignores the requested type' do
    reader = Object.new
    reader.define_singleton_method(:find_unit) { |identifier, type:| { 'identifier' => identifier, 'type' => 'poro' } }
    expect { described_class.new(reader).find('Report', 'model') }
      .to raise_error(Woods::ExtractionError, /model:Report/)
  end

  it 'refuses an injected reader that returns another identifier' do
    reader = Object.new
    reader.define_singleton_method(:find_unit) { |_, type:| { 'identifier' => 'Other', 'type' => type } }
    expect { described_class.new(reader).find('Report', 'model') }
      .to raise_error(Woods::ExtractionError, /model:Report/)
  end

  it 'does not silently retry unsupported typed lookups as a bare identifier' do
    reader = Object.new
    reader.define_singleton_method(:find_unit) { |identifier| { 'identifier' => identifier, 'type' => 'model' } }
    expect { described_class.new(reader).find('Report', 'model') }
      .to raise_error(Woods::ExtractionError, /requires typed lookup/)
  end

  it 'requires the actual type when an injected reader lists a mixed bucket' do
    reader = Object.new
    reader.define_singleton_method(:list_units) { |type:| type == 'graphql' ? [{ 'identifier' => 'Query' }] : [] }
    expect { described_class.new(reader).all }
      .to raise_error(Woods::ExtractionError, /requires actual type: Query/)
  end
end
