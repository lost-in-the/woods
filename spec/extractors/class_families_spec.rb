# frozen_string_literal: true

require 'spec_helper'
require 'active_support/core_ext/string/inflections'
require 'woods/extractors/class_families'

RSpec.describe Woods::Extractors::ClassFamilies do
  include_context 'extractor setup'

  before do
    stub_const('ActiveJob::Base', Class.new)
    stub_const('FamilyFixture', Module.new)
  end

  def load_source(relative, source)
    path = create_file(relative, source)
    load path
    path
  end

  it 'gives the job family exactly the classes JobAncestry admits' do
    load_source('app/models/family_fixture/sync.rb', "class FamilyFixture::Sync < ActiveJob::Base\nend\n")
    load_source('app/models/family_fixture/factory.rb',
                "FamilyFixture.const_set(:Generated, Class.new(ActiveJob::Base))\n")

    expect(described_class.owner_of(FamilyFixture::Sync)).to eq(:jobs)
    expect(described_class.owner_of(FamilyFixture::Generated)).to be_nil
  end
end
