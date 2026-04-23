# frozen_string_literal: true

require 'spec_helper'
require 'benchmark'
require 'woods/storage/vector_store'

# Wall-clock regression guard for the cosine kernel.
#
# The Phase 0 bench (bench/vector_query_and_serialization.rb) is the
# full measurement harness; this spec is the lightweight version that
# runs in CI and fails loud if a future change regresses the kernel
# past a bound. Numbers are derived from the initial measurement
# (Ruby 3.3 arm64-darwin23, admin-shape 12,771 × 768) with generous
# headroom so it passes across Ruby versions and CI hardware.
#
# Tagged `:perf` — opt in with `rspec --tag perf`. Not in the default
# run because wall-clock is jittery on shared runners; failures would
# be noise. Intended to be invoked from a separate CI job against a
# predictable box when we wire it in.
RSpec.describe 'InMemory vector search latency', :perf do
  it 'stays under 1500 ms for a 12 771-vector, 768-dim search' do
    store = Woods::Storage::VectorStore::InMemory.new
    rng = Random.new(42)
    12_771.times do |i|
      v = Array.new(768) { rng.rand(-1.0..1.0) }
      mag = Math.sqrt(v.sum { |x| x * x })
      v.map! { |x| x / mag } unless mag.zero?
      store.store("Unit_#{i}", v, { type: i.even? ? 'model' : 'service' })
    end
    query = Array.new(768) { rng.rand(-1.0..1.0) }

    # Warm inline caches and stabilise GC.
    3.times { store.search(query, limit: 10) }
    GC.start

    elapsed = Benchmark.realtime { store.search(query, limit: 10) }

    # Observed ~500 ms on a modern laptop; 1500 ms is ~3× headroom for
    # shared CI runners without being so loose that a regression hides.
    # If this starts failing, compare against bench/vector_query_and_serialization.rb
    # to see whether it's a real slowdown or a noisy runner.
    expect(elapsed).to be < 1.5
  end

  it 'stays within its allocation budget on a 1000-vector search' do
    # Duplicates the allocation bound in spec/storage/vector_store_spec.rb
    # — included here so the :perf suite can stand alone as a regression
    # gate without depending on the full vector_store suite running.
    store = Woods::Storage::VectorStore::InMemory.new
    1000.times { |i| store.store("v_#{i}", Array.new(256) { rand(-1.0..1.0) }) }
    query = Array.new(256) { rand(-1.0..1.0) }

    3.times { store.search(query, limit: 10) }
    GC.start

    before = GC.stat(:total_allocated_objects)
    store.search(query, limit: 10)
    after = GC.stat(:total_allocated_objects)

    expect(after - before).to be < 5000
  end
end
