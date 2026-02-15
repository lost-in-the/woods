# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/observability/instrumentation'

RSpec.describe CodebaseIndex::Observability::Instrumentation do
  describe '.instrument' do
    context 'when ActiveSupport::Notifications is available' do
      before do
        stub_const('ActiveSupport::Notifications', Class.new do
          def self.instrument(_event, payload = {})
            yield payload if block_given?
          end
        end)
      end

      it 'delegates to ActiveSupport::Notifications.instrument' do
        called_with = nil
        allow(ActiveSupport::Notifications).to receive(:instrument) do |event, payload, &block|
          called_with = { event: event, payload: payload }
          block&.call(payload)
        end

        result = described_class.instrument('codebase_index.extraction', { unit: 'User' }) { 42 }

        expect(called_with[:event]).to eq('codebase_index.extraction')
        expect(called_with[:payload]).to eq({ unit: 'User' })
        expect(result).to eq(42)
      end

      it 'passes the payload through' do
        yielded_payload = nil
        described_class.instrument('test.event', { key: 'value' }) do |payload|
          yielded_payload = payload
          'result'
        end

        expect(yielded_payload).to eq({ key: 'value' })
      end
    end

    context 'when ActiveSupport::Notifications is not available' do
      before do
        hide_const('ActiveSupport::Notifications')
      end

      it 'yields the block directly' do
        result = described_class.instrument('test.event', { key: 'value' }) { 42 }

        expect(result).to eq(42)
      end

      it 'works without a block' do
        expect { described_class.instrument('test.event') }.not_to raise_error
      end
    end
  end
end
