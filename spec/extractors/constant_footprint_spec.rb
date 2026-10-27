# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/constant_footprint'

RSpec.describe Woods::Extractors::ConstantFootprint do
  def touched(before, after)
    described_class.touched_names(described_class.call(before), described_class.call(after))
  end

  it 'ignores a method body edit' do
    expect(touched("class Card\n  def a = 1\nend", "class Card\n  def a = 2\n  def b = 3\nend")).to be_empty
  end

  it 'reports a constant added, removed or renamed by its last segment' do
    expect(touched("module Billing\nend", "module Billing\n  class Card; end\nend")).to eq(Set['Card'])
    expect(touched('class Billing::Card; end', '')).to eq(Set['Card'])
    expect(touched('class A; end', 'class B; end')).to eq(Set['A', 'B'])
  end

  it 'retains qualified touched constants for ancestry matching without changing leaf names' do
    before = described_class.call('class Importers::Base; end')
    after = described_class.call('class Importers::Base; include Fancy; end')

    expect(described_class.touched_constants(before, after)).to eq(Set['Importers::Base'])
    expect(described_class.touched_names(before, after)).to eq(Set['Base'])
  end

  it 'does not count a namespace that was already defined being plainly reopened' do
    before = described_class.call('')
    after = described_class.call("module Billing\n  class Card; end\nend")

    expect(described_class.touched_names(before, after, existing: ->(name) { name == 'Billing' })).to eq(Set['Card'])
    expect(described_class.touched_names(before, after)).to eq(Set['Billing', 'Card'])
  end

  it 'counts a reopened namespace that gains ancestry' do
    before = described_class.call('')
    after = described_class.call("module Billing\n  include Kit\nend")

    expect(described_class.touched_names(before, after, existing: ->(_name) { true })).to eq(Set['Billing'])
  end

  it 'reports a re-parented class' do
    expect(touched('class Card < Base; end', 'class Card < Other; end')).to eq(Set['Card'])
  end

  it 'reports a changed alias value but not a changed comment' do
    expect(touched('Card = Ui::Card', 'Card = Admin::Card')).to eq(Set['Card'])
    expect(touched("# one\nCard = Ui::Card", "# two\nCard = Ui::Card")).to be_empty
  end

  it 'reports a class whose ancestry changes, wherever the include sits' do
    inside_hook = "module Fancy\n  included do\n    include Kit\n  end\nend"

    expect(touched("class Card\nend", "class Card\n  include Kit\nend")).to eq(Set['Card'])
    expect(touched("module Fancy\n  included do\n  end\nend", inside_hook)).to eq(Set['Fancy'])
    expect(touched('class A; end', "class A; end\nApplicationComponent.include(Kit)"))
      .to eq(Set['ApplicationComponent'])
  end

  it 'reports a visibility declaration' do
    expect(touched('class A; B = 1; end', 'class A; B = 1; private_constant :B; end')).to eq(Set['B'])
  end

  it 'reports a multiple assignment value' do
    expect(touched('A, B = 1, 2', 'A, B = 1, 3')).to eq(Set['A', 'B'])
  end

  it 'is nil when a constant is created by name, autoloaded, or named like a Phlex Kit method' do
    expect(touched('class A; end', "class A; end\nObject.const_set(:B, 1)")).to be_nil
    expect(touched('class A; end', "class A\n  autoload :B, 'b'\nend")).to be_nil
    expect(touched('module Kit; end', "module Kit\n  def Header = 1\nend")).to be_nil
  end

  it 'is nil for source that does not parse' do
    expect(touched('class A; end', 'class A')).to be_nil
  end
end
