# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/bootstrap_state'

RSpec.describe Woods::MCP::BootstrapState do
  subject(:state) { described_class.new }

  describe 'initial state' do
    it 'starts in :initializing status' do
      expect(state.status).to eq(:initializing)
    end

    it 'has no reason' do
      expect(state.reason).to be_nil
    end

    it 'has no hydrated_at' do
      expect(state.hydrated_at).to be_nil
    end

    it 'has no degraded_since' do
      expect(state.degraded_since).to be_nil
    end
  end

  describe '#mark' do
    context 'transitioning to :hydrating' do
      it 'sets status to :hydrating' do
        state.mark(:hydrating)
        expect(state.status).to eq(:hydrating)
      end

      it 'leaves hydrated_at nil' do
        state.mark(:hydrating)
        expect(state.hydrated_at).to be_nil
      end
    end

    context 'transitioning to :hydrated' do
      it 'sets status to :hydrated' do
        state.mark(:hydrated)
        expect(state.status).to eq(:hydrated)
      end

      it 'records hydrated_at' do
        t = Time.utc(2026, 4, 23, 3, 42, 17)
        state.mark(:hydrated, now: t)
        expect(state.hydrated_at).to eq(t)
      end

      it 'leaves degraded_since nil' do
        state.mark(:hydrated)
        expect(state.degraded_since).to be_nil
      end
    end

    context 'transitioning to :degraded' do
      let(:err) { RuntimeError.new('connection refused') }

      it 'sets status to :degraded' do
        state.mark(:degraded, reason: err)
        expect(state.status).to eq(:degraded)
      end

      it 'stores the reason exception' do
        state.mark(:degraded, reason: err)
        expect(state.reason).to eq(err)
      end

      it 'records degraded_since' do
        t = Time.utc(2026, 4, 23, 3, 42, 18)
        state.mark(:degraded, reason: err, now: t)
        expect(state.degraded_since).to eq(t)
      end

      it 'leaves hydrated_at nil' do
        state.mark(:degraded, reason: err)
        expect(state.hydrated_at).to be_nil
      end
    end

    context 'transitioning to :failed' do
      let(:err) { StandardError.new('bad config') }

      it 'sets status to :failed' do
        state.mark(:failed, reason: err)
        expect(state.status).to eq(:failed)
      end

      it 'stores the reason exception' do
        state.mark(:failed, reason: err)
        expect(state.reason).to eq(err)
      end

      it 'leaves hydrated_at and degraded_since nil' do
        state.mark(:failed, reason: err)
        expect(state.hydrated_at).to be_nil
        expect(state.degraded_since).to be_nil
      end
    end

    context 'with an unrecognised status' do
      it 'raises ArgumentError' do
        expect { state.mark(:unknown_state) }.to raise_error(ArgumentError, /unknown_state/)
      end

      it 'mentions all valid statuses in the message' do
        state.mark(:bogus)
      rescue ArgumentError => e
        described_class::VALID_STATUSES.each do |s|
          expect(e.message).to include(s.inspect)
        end
      end
    end

    it 'returns self for chaining' do
      expect(state.mark(:hydrating)).to be(state)
    end
  end

  describe '#to_h' do
    it 'includes :status key' do
      expect(state.to_h).to include(status: :initializing)
    end

    it 'omits :reason when nil' do
      expect(state.to_h).not_to have_key(:reason)
    end

    it 'omits :hydrated_at when nil' do
      expect(state.to_h).not_to have_key(:hydrated_at)
    end

    it 'omits :degraded_since when nil' do
      expect(state.to_h).not_to have_key(:degraded_since)
    end

    context 'after :hydrated transition' do
      let(:t) { Time.utc(2026, 4, 23, 3, 42, 17) }

      before { state.mark(:hydrated, now: t) }

      it 'includes hydrated_at as ISO8601 string' do
        expect(state.to_h[:hydrated_at]).to eq(t.iso8601)
      end

      it 'does not include reason' do
        expect(state.to_h).not_to have_key(:reason)
      end
    end

    context 'after :degraded transition with reason' do
      let(:err) { RuntimeError.new('connection refused') }
      let(:t)   { Time.utc(2026, 4, 23, 3, 42, 18) }

      before { state.mark(:degraded, reason: err, now: t) }

      it 'includes reason as a class:message string' do
        expect(state.to_h[:reason]).to eq('RuntimeError: connection refused')
      end

      it 'includes degraded_since as ISO8601 string' do
        expect(state.to_h[:degraded_since]).to eq(t.iso8601)
      end
    end
  end

  # M7: the reload-phase degraded condition is deliberately separate from the
  # boot machinery — a failed reload leaves the previous aligned generation
  # served, so the boot status must not flip and hydration_failures must stay
  # empty.
  describe 'reload-failure condition' do
    it 'is absent by default' do
      expect(state.reload_failure).to be_nil
      expect(state.reload_failed?).to be(false)
      expect(state.to_h).not_to have_key(:reload_failure)
    end

    it 'records the pinned reload-phase payload shape' do
      state.record_reload_failure(generation: 7, stores: [:vector], reason: 'RuntimeError: dump truncated')

      expect(state.reload_failed?).to be(true)
      expect(state.reload_failure).to eq(
        phase: 'reload',
        generation: 7,
        stores: %w[vector],
        reason: 'RuntimeError: dump truncated'
      )
    end

    it 'exposes the condition additively in to_h without touching boot state' do
      state.mark(:hydrated)
      state.record_reload_failure(generation: 7, stores: %w[vector metadata], reason: 'RuntimeError: offline')

      expect(state.to_h[:reload_failure]).to include(phase: 'reload', generation: 7)
      expect(state.to_h[:status]).to eq(:hydrated)
      expect(state.hydration_failures).to be_empty
    end

    it 'normalizes store names to strings' do
      state.record_reload_failure(generation: 7, stores: %w[metadata], reason: 'x')
      expect(state.reload_failure[:stores]).to eq(%w[metadata])
    end

    it 'clears on recovery' do
      state.record_reload_failure(generation: 7, stores: [:vector], reason: 'x')
      state.clear_reload_failure!

      expect(state.reload_failed?).to be(false)
      expect(state.reload_failure).to be_nil
      expect(state.to_h).not_to have_key(:reload_failure)
    end
  end
end
