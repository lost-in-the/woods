# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/feedback/gap_detector'

RSpec.describe CodebaseIndex::Feedback::GapDetector do
  let(:feedback_store) { instance_double('CodebaseIndex::Feedback::Store') }

  subject(:detector) { described_class.new(feedback_store: feedback_store) }

  describe '#detect' do
    context 'with low-score queries' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([
                                                                { 'query' => 'payment flow', 'score' => 1 },
                                                                { 'query' => 'payment processing', 'score' => 2 },
                                                                { 'query' => 'how auth works', 'score' => 5 }
                                                              ])
        allow(feedback_store).to receive(:gaps).and_return([])
      end

      it 'identifies repeated low-score query patterns' do
        issues = detector.detect
        low_score = issues.find { |i| i[:type] == :repeated_low_scores }
        expect(low_score).not_to be_nil
        expect(low_score[:pattern]).to include('payment')
      end
    end

    context 'with gap reports' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([])
        allow(feedback_store).to receive(:gaps).and_return([
                                                             { 'missing_unit' => 'PaymentService',
                                                               'unit_type' => 'service' },
                                                             { 'missing_unit' => 'PaymentService',
                                                               'unit_type' => 'service' },
                                                             { 'missing_unit' => 'RefundJob', 'unit_type' => 'job' }
                                                           ])
      end

      it 'identifies frequently reported missing units' do
        issues = detector.detect
        freq = issues.find { |i| i[:type] == :frequently_missing }
        expect(freq).not_to be_nil
        expect(freq[:unit]).to eq('PaymentService')
        expect(freq[:count]).to eq(2)
      end
    end

    context 'with no feedback' do
      before do
        allow(feedback_store).to receive(:ratings).and_return([])
        allow(feedback_store).to receive(:gaps).and_return([])
      end

      it 'returns empty array' do
        expect(detector.detect).to eq([])
      end
    end
  end
end
