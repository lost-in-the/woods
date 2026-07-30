# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/operator/status_reporter'

RSpec.describe Woods::Operator::StatusReporter do
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

    context 'when the manifest contains non-ASCII bytes' do
      # Regression — B-077 / #189. read_manifest used a bare File.read, which
      # tags the bytes with the process's default external encoding — US-ASCII
      # under LANG=C, which is how this suite runs — so a manifest with a
      # non-ASCII branch name raised Encoding::InvalidByteSequenceError out of
      # JSON.parse (not the JSON::ParserError being rescued) and took the whole
      # status report down with it.
      before do
        manifest = {
          'extracted_at' => '2026-02-15T10:00:00Z',
          'total_units' => 1,
          'counts' => { 'models' => 1 },
          'git_sha' => 'abc123',
          'git_branch' => 'fix/café-menu'
        }
        Woods::AtomicFile.write(File.join(output_dir, 'manifest.json'), JSON.generate(manifest))
      end

      it 'reads the manifest instead of raising' do
        status = reporter.report

        expect(status[:git_branch]).to eq('fix/café-menu')
        expect(status[:total_units]).to eq(1)
      end
    end

    context 'when the manifest is unparseable' do
      it 'degrades to :not_extracted like a missing manifest' do
        File.write(File.join(output_dir, 'manifest.json'), 'not json')

        expect(reporter.report[:status]).to eq(:not_extracted)
      end
    end

    context 'when the manifest cannot be read' do
      it 'degrades to :not_extracted like a missing manifest' do
        File.write(File.join(output_dir, 'manifest.json'), '{}')
        allow(Woods::AtomicFile).to receive(:read).and_raise(Errno::EACCES)

        expect(reporter.report[:status]).to eq(:not_extracted)
      end
    end
  end
end
