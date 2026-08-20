# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'release gemspec dependency contract' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, 'woods.gemspec')) }

  def runtime_requirement(name)
    gemspec.runtime_dependencies.find { |dependency| dependency.name == name }.requirement
  end

  it 'supports msgpack 1.5 through the 1.x series without admitting 2.0' do
    requirement = runtime_requirement('msgpack')

    expect(requirement).to be_satisfied_by(Gem::Version.new('1.5.0'))
    expect(requirement).to be_satisfied_by(Gem::Version.new('1.99.0'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('1.4.9'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('2.0.0'))
  end

  it 'supports Rails 6 through 8 without admitting Rails 9' do
    requirement = runtime_requirement('railties')

    expect(requirement).to be_satisfied_by(Gem::Version.new('6.0.0'))
    expect(requirement).to be_satisfied_by(Gem::Version.new('8.99.0'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('5.2.8'))
    expect(requirement).not_to be_satisfied_by(Gem::Version.new('9.0.0'))
  end
end
