# frozen_string_literal: true

require 'spec_helper'
require 'woods/published_index'
require 'woods/checks/moved_messages'

# `Woods::Checks::MovedMessages` reads two `Woods::PublishedIndex`-shaped
# generations (Task 11 name; the design doc's "IndexReader" was renamed) and
# looks for a public method name that left one unit and appeared in another
# while `:test_coverage` did not follow. Per the 2026-09-09 ruling this is
# reported as a *candidate* move into an unmapped-tests unit, never a proven
# coverage loss: the check cannot tell a real refactor from two unrelated
# methods that happen to share a name and kind.
RSpec.describe Woods::Checks::MovedMessages do
  # A reader double shaped like Woods::PublishedIndex: #units, #unit, #edges.
  def reader(units:, coverage_targets: [])
    entries = units.keys.map { |identifier| { 'identifier' => identifier, 'type' => units[identifier]['type'] } }
    coverage = coverage_targets.map do |target|
      { from: "spec/#{target.downcase}_spec.rb", to: target, via: 'test_coverage' }
    end
    instance_double(Woods::PublishedIndex, units: entries).tap do |double|
      allow(double).to receive(:unit) { |identifier| units[identifier] }
      allow(double).to receive(:edges).with(via: 'test_coverage').and_return(coverage)
    end
  end

  def unit(type, key, *methods)
    { 'type' => type, 'metadata' => { key => methods } }
  end

  it 'reports a candidate move when a public method left a covered unit for an uncovered one' do
    before = reader(units: { 'Checkout' => unit('service', 'public_methods', 'call', 'total'),
                             'Pricing' => unit('service', 'public_methods', 'rate') },
                    coverage_targets: ['Checkout'])
    after = reader(units: { 'Checkout' => unit('service', 'public_methods', 'call'),
                            'Pricing' => unit('service', 'public_methods', 'rate', 'total') },
                   coverage_targets: ['Checkout'])

    findings = described_class.new(before: before, after: after).run

    expect(findings.map(&:to_h)).to eq([
                                         { method: 'total', kind: :instance, from_unit: 'Checkout', to_unit: 'Pricing',
                                           covered_before: true, covered_after: false }
                                       ])
  end

  it 'stays silent when the destination is covered, when the method was never covered, or when nothing moved' do
    before = reader(units: { 'Checkout' => unit('service', 'public_methods', 'total'),
                             'Pricing' => unit('service', 'public_methods'),
                             'Loose' => unit('service', 'public_methods', 'helper') },
                    coverage_targets: ['Checkout'])
    after = reader(units: { 'Checkout' => unit('service', 'public_methods'),
                            'Pricing' => unit('service', 'public_methods', 'total'),
                            'Loose' => unit('service', 'public_methods'),
                            'Other' => unit('service', 'public_methods', 'helper') },
                   coverage_targets: %w[Checkout Pricing])

    expect(described_class.new(before: before, after: after).run).to eq([])
  end

  it 'ignores units with no method lists at all' do
    before = reader(units: { 'Post' => unit('model', 'instance_methods', 'normalize'),
                             'Route' => { 'type' => 'route' } },
                    coverage_targets: ['Post'])
    after = reader(units: { 'Post' => unit('model', 'instance_methods'),
                            'Route' => { 'type' => 'route' } },
                   coverage_targets: ['Post'])

    # `normalize` vanished with nowhere it reappeared, so this is a plain
    # removal, not a move: Route carries no method list to receive it.
    expect(described_class.new(before: before, after: after).run).to eq([])
  end

  it 'does not match an instance method against a class method of the same name (kind collision)' do
    model = unit('model', 'instance_methods', 'normalize')
    poro_before = { 'type' => 'poro', 'metadata' => {} }
    poro_after = unit('poro', 'class_methods', 'normalize')

    before = reader(units: { 'Post' => model, 'Slug' => poro_before }, coverage_targets: ['Post'])
    after = reader(units: { 'Post' => unit('model', 'instance_methods'), 'Slug' => poro_after },
                   coverage_targets: ['Post'])

    findings = described_class.new(before: before, after: after).run

    expect(findings).to eq([])
  end

  it 'normalizes a self.-prefixed public method to a class method, matching a class_methods entry of the same kind' do
    before = reader(units: { 'Alpha' => unit('service', 'public_methods', 'self.build', 'run'),
                             'Beta' => unit('service', 'class_methods') },
                    coverage_targets: ['Alpha'])
    after = reader(units: { 'Alpha' => unit('service', 'public_methods', 'run'),
                            'Beta' => unit('service', 'class_methods', 'build') },
                   coverage_targets: ['Alpha'])

    findings = described_class.new(before: before, after: after).run

    expect(findings.map(&:to_h)).to eq([
                                         { method: 'build', kind: :class, from_unit: 'Alpha', to_unit: 'Beta',
                                           covered_before: true, covered_after: false }
                                       ])
  end

  it 'stays silent when the destination already carries unrelated test coverage that predates the move' do
    before = reader(units: { 'Checkout' => unit('service', 'public_methods', 'total'),
                             'Pricing' => unit('service', 'public_methods') },
                    coverage_targets: %w[Checkout Pricing])
    after = reader(units: { 'Checkout' => unit('service', 'public_methods'),
                            'Pricing' => unit('service', 'public_methods', 'total') },
                   coverage_targets: %w[Checkout Pricing])

    expect(described_class.new(before: before, after: after).run).to eq([])
  end

  it 'flags an unrelated removal and addition of the same name, since the check cannot prove a real move' do
    before = reader(units: { 'Alpha' => unit('service', 'public_methods', 'process'),
                             'Beta' => unit('service', 'public_methods') },
                    coverage_targets: ['Alpha'])
    after = reader(units: { 'Alpha' => unit('service', 'public_methods'),
                            'Beta' => unit('service', 'public_methods', 'process') },
                   coverage_targets: ['Alpha'])

    findings = described_class.new(before: before, after: after).run

    expect(findings.map(&:to_h)).to eq([
                                         { method: 'process', kind: :instance, from_unit: 'Alpha', to_unit: 'Beta',
                                           covered_before: true, covered_after: false }
                                       ])
  end
end
