# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/confirmation'

RSpec.describe CodebaseIndex::Console::Confirmation do
  describe '#request_confirmation' do
    context 'when auto-approved' do
      subject(:confirmation) { described_class.new(mode: :auto_approve) }

      it 'returns true without blocking' do
        result = confirmation.request_confirmation(
          tool: 'console_eval',
          description: 'Execute: 1 + 1',
          params: { code: '1 + 1' }
        )
        expect(result).to be true
      end
    end

    context 'when auto-denied' do
      subject(:confirmation) { described_class.new(mode: :auto_deny) }

      it 'raises ConfirmationDeniedError' do
        expect do
          confirmation.request_confirmation(
            tool: 'console_eval',
            description: 'Execute: dangerous_code',
            params: { code: 'dangerous_code' }
          )
        end.to raise_error(CodebaseIndex::Console::ConfirmationDeniedError, /denied/i)
      end
    end

    context 'when using callback mode' do
      it 'calls the callback with request details' do
        received = nil
        callback = lambda { |request|
          received = request
          true
        }
        confirmation = described_class.new(mode: :callback, callback: callback)

        confirmation.request_confirmation(
          tool: 'console_eval',
          description: 'Execute: 1 + 1',
          params: { code: '1 + 1' }
        )

        expect(received[:tool]).to eq('console_eval')
        expect(received[:description]).to eq('Execute: 1 + 1')
        expect(received[:params]).to eq({ code: '1 + 1' })
      end

      it 'raises ConfirmationDeniedError when callback returns false' do
        callback = ->(_request) { false }
        confirmation = described_class.new(mode: :callback, callback: callback)

        expect do
          confirmation.request_confirmation(
            tool: 'console_eval',
            description: 'test',
            params: {}
          )
        end.to raise_error(CodebaseIndex::Console::ConfirmationDeniedError)
      end

      it 'raises if no callback provided in callback mode' do
        expect { described_class.new(mode: :callback) }
          .to raise_error(ArgumentError, /callback required/i)
      end
    end
  end

  describe '#pending_count' do
    it 'tracks confirmation history' do
      confirmation = described_class.new(mode: :auto_approve)
      expect(confirmation.history).to eq([])

      confirmation.request_confirmation(tool: 'eval', description: 'test', params: {})

      expect(confirmation.history.size).to eq(1)
      expect(confirmation.history.first[:approved]).to be true
    end

    it 'tracks denied confirmations in history' do
      confirmation = described_class.new(mode: :auto_deny)

      begin
        confirmation.request_confirmation(tool: 'eval', description: 'test', params: {})
      rescue CodebaseIndex::Console::ConfirmationDeniedError
        # expected
      end

      expect(confirmation.history.size).to eq(1)
      expect(confirmation.history.first[:approved]).to be false
    end
  end
end
