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

  it 'answers from bases resolved once, without resolving them again per class' do
    stub_const('ActionMailer::Base', Class.new)
    mailer = Class.new(ActionMailer::Base)
    lookup = Woods::SourceReferences::RuntimeLookup.new
    bases = described_class.resolve_bases(lookup)

    allow(lookup).to receive(:call).and_call_original
    expect(described_class.owner_of(mailer, lookup, bases: bases)).to eq(:mailers)
    expect(described_class.owner_of(Class.new, lookup, bases: bases)).to be_nil
    expect(lookup).not_to have_received(:call).with('::ActionMailer::Base')
  end

  it 'never assigns a module to a family' do
    stub_const('ActiveModel::Serializer', Class.new)
    namespace = Module.new
    stub_const('FamilyFixture::Admin', namespace)

    expect(described_class.owner_of(namespace)).to be_nil
    expect(described_class.owner_of(Module)).to be_nil
  end

  it 'gives the job family exactly the classes JobAncestry admits' do
    load_source('app/models/family_fixture/sync.rb', "class FamilyFixture::Sync < ActiveJob::Base\nend\n")
    load_source('app/models/family_fixture/factory.rb',
                "FamilyFixture.const_set(:Generated, Class.new(ActiveJob::Base))\n")

    expect(described_class.owner_of(FamilyFixture::Sync)).to eq(:jobs)
    expect(described_class.owner_of(FamilyFixture::Generated)).to be_nil
  end
end
