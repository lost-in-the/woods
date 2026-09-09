# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/preparer'

# The release contract, proven in every state a checked-in tree is ever in.
#
# `ReleaseStateTrees` runs the real transitions over the release fixture once,
# so alpha, prerelease, and final trees all exist in a single run. The checkout
# the suite is running in is checked against the same invariants, whichever of
# the three it happens to be in, so a release commit passes its own specs.
RSpec.describe 'release state matrix' do
  ReleaseStateTrees::STATES.each do |state|
    context "a tree generated at the #{state} state" do
      let(:release_root) { ReleaseStateTrees.roots.fetch(state) }
      let(:freshly_released) { true }

      it_behaves_like 'a coherent release state'
    end
  end

  context 'the checkout this suite is running in' do
    let(:release_root) { release_checkout_root }

    it_behaves_like 'a coherent release state'
  end

  it 'walks the fixture through one version per state' do
    versions = ReleaseStateTrees::STATES.map do |state|
      Woods::Release::Preparer.current_state(ReleaseStateTrees.roots.fetch(state)).to_s
    end

    expect(versions).to eq(%w[2.0.0.alpha 2.0.0.beta1 2.0.0])
  end
end
