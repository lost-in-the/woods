# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'codebase_index/feedback/store'

RSpec.describe CodebaseIndex::Feedback::Store do
  let(:feedback_dir) { Dir.mktmpdir }
  let(:feedback_path) { File.join(feedback_dir, 'feedback.jsonl') }

  after { FileUtils.rm_rf(feedback_dir) }

  subject(:store) { described_class.new(path: feedback_path) }

  describe '#record_rating' do
    it 'appends a rating entry to the JSONL file' do
      store.record_rating(query: 'How does User work?', score: 4, comment: 'Good')
      entries = store.all_entries
      expect(entries.size).to eq(1)
      expect(entries.first['type']).to eq('rating')
      expect(entries.first['score']).to eq(4)
      expect(entries.first['query']).to eq('How does User work?')
    end

    it 'appends multiple entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_rating(query: 'q2', score: 5)
      expect(store.all_entries.size).to eq(2)
    end

    it 'includes timestamp' do
      store.record_rating(query: 'q', score: 4)
      expect(store.all_entries.first['timestamp']).not_to be_nil
    end

    context 'with invalid scores' do
      it 'rejects nil score' do
        expect { store.record_rating(query: 'q', score: nil) }
          .to raise_error(ArgumentError, /score must be/)
      end

      it 'rejects string score' do
        expect { store.record_rating(query: 'q', score: '4') }
          .to raise_error(ArgumentError, /score must be/)
      end

      it 'rejects score of 0' do
        expect { store.record_rating(query: 'q', score: 0) }
          .to raise_error(ArgumentError, /score must be/)
      end

      it 'rejects score of 6' do
        expect { store.record_rating(query: 'q', score: 6) }
          .to raise_error(ArgumentError, /score must be/)
      end

      it 'rejects negative score' do
        expect { store.record_rating(query: 'q', score: -1) }
          .to raise_error(ArgumentError, /score must be/)
      end

      it 'rejects float score' do
        expect { store.record_rating(query: 'q', score: 3.5) }
          .to raise_error(ArgumentError, /score must be/)
      end
    end
  end

  describe '#record_gap' do
    it 'appends a gap report entry' do
      store.record_gap(query: 'What about payments?', missing_unit: 'PaymentService', unit_type: 'service')
      entries = store.all_entries
      expect(entries.size).to eq(1)
      expect(entries.first['type']).to eq('gap')
      expect(entries.first['missing_unit']).to eq('PaymentService')
    end
  end

  describe '#all_entries' do
    it 'returns empty array when file does not exist' do
      new_store = described_class.new(path: File.join(feedback_dir, 'nonexistent.jsonl'))
      expect(new_store.all_entries).to eq([])
    end
  end

  describe '#ratings' do
    it 'filters to only rating entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_gap(query: 'q2', missing_unit: 'X', unit_type: 'service')
      store.record_rating(query: 'q3', score: 5)
      expect(store.ratings.size).to eq(2)
    end
  end

  describe '#gaps' do
    it 'filters to only gap entries' do
      store.record_rating(query: 'q1', score: 3)
      store.record_gap(query: 'q2', missing_unit: 'X', unit_type: 'service')
      expect(store.gaps.size).to eq(1)
    end
  end

  describe '#average_score' do
    it 'computes mean of all rating scores' do
      store.record_rating(query: 'q1', score: 2)
      store.record_rating(query: 'q2', score: 4)
      expect(store.average_score).to eq(3.0)
    end

    it 'returns nil when no ratings' do
      expect(store.average_score).to be_nil
    end
  end
end
