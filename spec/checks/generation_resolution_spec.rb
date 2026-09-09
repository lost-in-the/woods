# frozen_string_literal: true

require 'spec_helper'
require 'woods/checks/generation_resolution'

# Pure function, no I/O (#280 / M14): `woods:check:moved_messages` needs to
# turn "no [from,to] given" plus a list of published generations into the
# pair it will actually open. Kept separate from the rake task so the
# defaulting rules (latest two; fill in whichever side is missing; refuse
# when there is no earlier generation) have their own spec independent of
# any on-disk index.
RSpec.describe Woods::Checks::GenerationResolution do
  it 'defaults to the latest two available generations' do
    expect(described_class.call([38, 40, 41, 42])).to eq([41, 42])
  end

  it 'accepts explicit from/to, including as rake-argument strings' do
    expect(described_class.call([1, 2, 3], from: '1', to: '3')).to eq([1, 3])
  end

  it 'defaults only the side that was not given explicitly' do
    expect(described_class.call([1, 2, 3], to: 2)).to eq([1, 2])
    expect(described_class.call([1, 2, 3], from: 1)).to eq([1, 3])
  end

  it 'returns nil when fewer than two generations are available and neither was given explicitly' do
    expect(described_class.call([42])).to be_nil
    expect(described_class.call([])).to be_nil
  end

  it 'returns nil when nothing is available before the resolved "to"' do
    expect(described_class.call([5], to: 5)).to be_nil
  end
end
