# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/operator/status_reporter'

RSpec.describe CodebaseIndex::Operator::StatusReporter do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(output_dir) }

  subject(:reporter) { described_class.new(output_dir: output_dir) }

  describe '#report' do
    context 'when manifest exists' do
      before do
        manifest = {
          'extracted_at' => '2026-02-15T10:00:00Z',
          'total_units' => 42,
          'counts' => { 'models' => 10, 'controllers' => 5, 'services' => 3 },
          'git_sha' => 'abc123',
          'git_branch' => 'main'
        }
        File.write(File.join(output_dir, 'manifest.json'), JSON.generate(manifest))
      end

      it 'returns status hash with extraction info' do
        status = reporter.report
        expect(status[:extracted_at]).to eq('2026-02-15T10:00:00Z')
        expect(status[:total_units]).to eq(42)
        expect(status[:git_sha]).to eq('abc123')
      end

      it 'includes unit counts by type' do
        status = reporter.report
        expect(status[:counts]).to eq({ 'models' => 10, 'controllers' => 5, 'services' => 3 })
      end

      it 'calculates staleness in seconds' do
        status = reporter.report
        expect(status[:staleness_seconds]).to be_a(Numeric)
        expect(status[:staleness_seconds]).to be > 0
      end

      it 'sets status to :ok when recent' do
        manifest = JSON.parse(File.read(File.join(output_dir, 'manifest.json')))
        manifest['extracted_at'] = Time.now.iso8601
        File.write(File.join(output_dir, 'manifest.json'), JSON.generate(manifest))

        status = reporter.report
        expect(status[:status]).to eq(:ok)
      end
    end

    context 'when manifest does not exist' do
      it 'returns status :not_extracted' do
        status = reporter.report
        expect(status[:status]).to eq(:not_extracted)
        expect(status[:total_units]).to eq(0)
      end
    end
  end
end
