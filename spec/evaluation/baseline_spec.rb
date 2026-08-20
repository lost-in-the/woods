# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/evaluation/baseline'

RSpec.describe Woods::Evaluation::Baseline do
  let(:fixture_path) { File.expand_path('../fixtures/evaluation_baseline.example.json', __dir__) }

  describe '.load' do
    it 'loads the checked-in example fixture' do
      data = described_class.load(fixture_path)

      expect(data.schema_version).to eq(1)
      expect(data.query_set).to eq('config/eval_queries.json')
    end

    it 'symbolizes threshold keys so they line up with aggregate keys' do
      data = described_class.load(fixture_path)

      expect(data.thresholds).to eq(mean_precision_at5: 0.0, mean_recall: 0.0, mean_mrr: 0.0)
    end

    it 'labels the example as a format fixture, not a real captured baseline' do
      data = described_class.load(fixture_path)

      expect(data.notes).to match(/NOT a captured v2 corpus baseline/)
      expect(data.captured_at).to be_nil
    end

    it 'raises a typed error for an unsupported schema_version' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'bad.json')
        File.write(path, JSON.generate('schema_version' => 99, 'thresholds' => {}))

        expect { described_class.load(path) }.to raise_error(Woods::Error, /schema_version/)
      end
    end

    it 'defaults thresholds to an empty hash when the field is absent' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'no_thresholds.json')
        File.write(path, JSON.generate('schema_version' => 1))

        expect(described_class.load(path).thresholds).to eq({})
      end
    end
  end
end
