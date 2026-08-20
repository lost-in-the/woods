# frozen_string_literal: true

require 'spec_helper'
require 'woods/session_tracer/solid_cache_coordination'

class FailsafeCoordinationCache
  attr_reader :events, :routed_keys, :uncached_calls

  def initialize
    @events = []
    @routed_keys = []
    @uncached_calls = 0
  end

  private

  def merged_options(options)
    options || {}
  end

  def normalize_key(key, _options)
    "normalized:#{key}"
  end

  def normalize_version(*)
    nil
  end

  def serialize_entry(*)
    'serialized-entry'
  end

  def bypass_local_cache
    @uncached_calls += 1
    yield
  end

  def instrument(operation, key, _options = nil)
    @events << [operation, key]
    yield({})
  end

  def reading_key(key, failsafe:, failsafe_returning:)
    @routed_keys << [key, failsafe]
    failsafe_returning
  end

  def writing_key(key, failsafe:, failsafe_returning:)
    @routed_keys << [key, failsafe]
    failsafe_returning
  end
end

RSpec.describe Woods::SessionTracer::SolidCacheCoordination do
  let(:cache) { FailsafeCoordinationCache.new }
  let(:coordination) { described_class.new(cache) }

  it 'raises a typed error when a routed read hits Solid Cache failsafe' do
    expect { coordination.read('owner') }
      .to raise_error(described_class::BackendError, /read.*owner/)

    expect(cache.routed_keys).to eq([['normalized:owner', :read_entry]])
    expect(cache.events).to eq([[:read, 'normalized:owner']])
    expect(cache.uncached_calls).to eq(1)
  end

  it 'raises a typed error when a routed conditional write hits Solid Cache failsafe' do
    expect { coordination.write_if_absent('directory', 'membership') }
      .to raise_error(described_class::BackendError, /write_if_absent.*directory/)

    expect(cache.routed_keys).to eq([['normalized:directory', :write_entry]])
    expect(cache.events).to eq([[:write, 'normalized:directory']])
    expect(cache.uncached_calls).to eq(1)
  end
end
