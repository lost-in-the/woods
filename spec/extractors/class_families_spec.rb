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

  it 'gives the serializer family descendants of an application serializer base' do
    stub_const('ActiveModel::Serializer', Class.new)
    load_source('app/serializers/family_fixture/app_serializer.rb', "class FamilyFixture::AppSerializer\nend\n")
    load_source('app/presenters/order_presenter.rb', "class FamilyFixture::OrderPresenter < FamilyFixture::AppSerializer\nend\n")

    expect(described_class.owner_of(FamilyFixture::OrderPresenter)).to eq(:serializers)
    expect(described_class.owner_of(FamilyFixture::AppSerializer)).to eq(:serializers)
  end

  it 'leaves a plain class under the application serializer directory to the sweep' do
    stub_const('ActiveModel::Serializer', Class.new)
    load_source('app/serializers/family_fixture/app_serializer.rb', "class FamilyFixture::AppSerializer\nend\n")
    load_source('app/presenters/plain_thing.rb', "class FamilyFixture::PlainThing\nend\n")

    expect(described_class.owner_of(FamilyFixture::PlainThing)).to be_nil
  end
end
