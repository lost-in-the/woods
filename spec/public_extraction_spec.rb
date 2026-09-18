# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/extractor'
require 'woods/rake_helpers'
require 'woods/coordination/pipeline_lock'
require 'woods/watch/daemon'

RSpec.describe 'public extraction helpers' do
  include_context 'isolated Woods runtime'

  around do |example|
    Dir.mktmpdir('woods-public-extraction') do |dir|
      @output_dir = dir
      example.run
    end
  end

  let(:extractor) { instance_double(Woods::Extractor, raise_on_publication_failure!: nil) }

  before do
    Woods.configuration.output_dir = @output_dir
    allow(Woods::Extractor).to receive(:new).with(output_dir: @output_dir).and_return(extractor)
  end

  def writer_lock
    Woods::Coordination::PipelineLock.new(lock_dir: @output_dir, name: Woods::Watch::Daemon::LOCK_NAME)
  end

  %i[extract! extract_changed!].each do |method|
    context method.to_s do
      let(:run) { -> { method == :extract! ? Woods.extract! : Woods.extract_changed!(['app/models/post.rb']) } }
      let(:raw_method) { method == :extract! ? :extract_all : :extract_changed }
      let(:result) { method == :extract! ? { models: [] } : ['Post'] }

      it 'holds the shared writer lock through extraction and the publication check, then releases it' do
        contender = writer_lock
        allow(extractor).to receive(raw_method) do
          expect(contender.acquire).to be(false)
          result
        end
        allow(extractor).to receive(:raise_on_publication_failure!) do
          expect(contender.acquire).to be(false)
        end
        expect(run.call).to eq(result)
        expect(contender.acquire).to be(true)
      ensure
        contender&.release
      end

      it 'refuses an occupied lock with a typed exception before constructing an extractor' do
        holder = writer_lock
        expect(holder.acquire).to be(true)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('WOODS_LOCK_WAIT', anything).and_return('0')
        expect(Woods::Extractor).not_to receive(:new)
        expect { run.call }.to raise_error(Woods::Coordination::LockError, /extraction lock/)
      ensure
        holder&.release
      end

      it 'raises publication failures and releases the lock for retry' do
        allow(extractor).to receive(raw_method).and_return(result)
        allow(extractor).to receive(:raise_on_publication_failure!).and_raise(Woods::ExtractionError, 'not published')
        expect { run.call }.to raise_error(Woods::ExtractionError, 'not published')
        contender = writer_lock
        expect(contender.acquire).to be(true)
      ensure
        contender&.release
      end

      it 'preserves extraction errors and releases the lock' do
        allow(extractor).to receive(raw_method).and_raise(Woods::ExtractionError, 'extraction failed')
        expect { run.call }.to raise_error(Woods::ExtractionError, 'extraction failed')
        contender = writer_lock
        expect(contender.acquire).to be(true)
      ensure
        contender&.release
      end
    end
  end
end
