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

  describe 'transitions release:prepare allows' do
    def prepare(current, target)
      described_class.validate_prepare!(parse(current), parse(target))
    end

    it 'cuts a beta, another beta, an rc, and the final release from the alpha line' do
      expect { prepare('2.0.0.alpha', '2.0.0.beta1') }.not_to raise_error
      expect { prepare('2.0.0.beta1', '2.0.0.beta2') }.not_to raise_error
      expect { prepare('2.0.0.beta2', '2.0.0.rc1') }.not_to raise_error
      expect { prepare('2.0.0.rc1', '2.0.0') }.not_to raise_error
      expect { prepare('2.0.0.alpha', '2.0.0') }.not_to raise_error
    end

    it 'refuses to move backwards' do
      expect { prepare('2.0.0.beta2', '2.0.0.beta1') }
        .to raise_error(described_class::InvalidTransition, /2\.0\.0\.beta1 does not come after/)
      expect { prepare('2.0.0.rc1', '2.0.0.beta3') }
        .to raise_error(described_class::InvalidTransition, /does not come after/)
      expect { prepare('2.0.0.beta1', '2.0.0.beta1') }
        .to raise_error(described_class::InvalidTransition, /does not come after/)
    end

    it 'refuses a version whose base is not the base main is developing' do
      expect { prepare('2.0.0.alpha', '2.1.0.beta1') }
        .to raise_error(described_class::InvalidTransition, /main is developing 2\.0\.0/)
      expect { prepare('2.0.0.alpha', '3.0.0') }
        .to raise_error(described_class::InvalidTransition, /main is developing 2\.0\.0/)
    end

    it 'refuses to prepare an alpha or to release twice without reopening' do
      expect { prepare('2.0.0.alpha', '2.1.0.alpha') }
        .to raise_error(described_class::InvalidTransition, /use release:reopen/)
      expect { prepare('2.0.0', '2.0.1') }
        .to raise_error(described_class::InvalidTransition, /already released/)
    end
  end

  describe 'transitions release:reopen allows' do
    def reopen(current, target)
      described_class.validate_reopen!(parse(current), parse(target))
    end

    it 'reopens a released tree into a later alpha' do
      expect { reopen('2.0.0', '2.0.1.alpha') }.not_to raise_error
      expect { reopen('2.0.0', '2.1.0.alpha') }.not_to raise_error
      expect { reopen('2.0.0', '3.0.0.alpha') }.not_to raise_error
    end

    it 'refuses a target that is not an alpha, is not later, or reopens an unreleased tree' do
      expect { reopen('2.0.0', '2.1.0.beta1') }
        .to raise_error(described_class::InvalidTransition, /release:reopen sets X\.Y\.Z\.alpha/)
      expect { reopen('2.0.0', '1.9.0.alpha') }
        .to raise_error(described_class::InvalidTransition, /does not come after/)
      expect { reopen('2.0.0.rc1', '2.1.0.alpha') }
        .to raise_error(described_class::InvalidTransition, /is not a final release/)
    end
  end
end
