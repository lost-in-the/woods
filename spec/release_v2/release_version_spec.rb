# frozen_string_literal: true

require 'spec_helper'
require 'woods/release/version_state'

RSpec.describe Woods::Release::VersionState do
  def parse(version)
    described_class.parse(version)
  end

  it 'classifies the four states main moves through' do
    expect(parse('2.0.0.alpha').state).to eq(:alpha)
    expect(parse('2.0.0.beta1').state).to eq(:beta)
    expect(parse('2.0.0.rc2').state).to eq(:rc)
    expect(parse('2.0.0').state).to eq(:final)
  end

  it 'treats beta and rc as the prerelease states and alpha as neither released nor publishable' do
    expect(parse('2.0.0.alpha')).to have_attributes(alpha?: true, prerelease?: false, final?: false)
    expect(parse('2.0.0.beta1')).to have_attributes(alpha?: false, prerelease?: true, final?: false)
    expect(parse('2.0.0.rc1')).to have_attributes(alpha?: false, prerelease?: true, final?: false)
    expect(parse('2.0.0')).to have_attributes(alpha?: false, prerelease?: false, final?: true)
  end

  it 'documents the base version in every state' do
    %w[2.0.0.alpha 2.0.0.beta3 2.0.0.rc1 2.0.0].each do |version|
      expect(parse(version).documented_version).to eq('2.0.0')
    end
  end

  it 'points an alpha at main and every releasable version at its own tag' do
    expect(parse('2.0.0.alpha').release_ref).to eq('main')
    expect(parse('2.0.0.beta1').release_ref).to eq('v2.0.0.beta1')
    expect(parse('2.0.0.rc1').release_ref).to eq('v2.0.0.rc1')
    expect(parse('2.0.0').release_ref).to eq('v2.0.0')
  end

  it 'refuses to name a tag for the development marker' do
    expect { parse('2.1.0.alpha').tag }
      .to raise_error(described_class::InvalidTransition, /2\.1\.0\.alpha is a development marker/)
  end

  it 'orders the states the way RubyGems does' do
    ordered = %w[2.0.0.alpha 2.0.0.beta1 2.0.0.beta2 2.0.0.rc1 2.0.0 2.1.0.alpha].map { |v| parse(v).gem_version }

    expect(ordered).to eq(ordered.sort)
    expect(parse('2.0.0.beta1').gem_version).to be_prerelease
    expect(parse('2.0.0').gem_version).not_to be_prerelease
  end

  it 'derives the approximate constraint that resolves the line once published' do
    expect(parse('2.0.0.beta1').approximate_constraint).to eq('~> 2.0')
    expect(parse('2.1.0.alpha').approximate_constraint).to eq('~> 2.1')
  end

  it 'rejects version shapes the flow does not produce' do
    [
      '2.0', '2.0.0.0', 'v2.0.0', '2.0.0-beta1', '2.0.0.pre', '2.0.0.alpha1', '2.0.0.beta', '2.0.0.rc', '2.0.0.beta0'
    ].each do |version|
      expect { parse(version) }.to raise_error(described_class::InvalidVersion), "expected #{version} to be rejected"
    end
  end
end
