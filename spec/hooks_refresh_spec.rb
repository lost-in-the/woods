# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'woods/extractor'
require 'woods/hooks/refresh'

RSpec.describe Woods::Hooks::Refresh do
  let(:extractor) { instance_double(Woods::Extractor, extract_all: {}, extract_changed: [], raise_on_publication_failure!: nil) }
  let(:environment) { instance_double(Rake::Task, invoke: nil) }

  def refresh(events, output: 'tmp/woods')
    described_class.new(Base64.strict_encode64(JSON.generate(version: 1, output: output, events: events)))
  end

  before do
    allow(Woods::RakeHelpers).to receive_messages(woods_task_root: '/application', woods_daemon_coverage: :none)
    allow(Woods::RakeHelpers).to receive(:woods_with_extraction_lock).and_yield
    allow(Woods::Extractor).to receive(:new).and_return(extractor)
    allow(Rake::Task).to receive(:[]).with(:environment).and_return(environment)
  end

  it 'preserves commas, whitespace and newlines in a JSON path without git parsing' do
    paths = ['app/services/a,b.rb', "app/views/a b\nc.html.erb"]
    refresh(paths.map { |path| { path: path, operation: 'update' } }).call
    expect(extractor).to have_received(:extract_changed).with(paths)
    expect(extractor).to have_received(:raise_on_publication_failure!)
  end

  it 'lets a restart input dominate a mixed batch and takes the publication lock' do
    refresh([{ path: 'app/jobs/pay.rb', operation: 'add' },
             { path: 'config/initializers/cache.rb', operation: 'update' }]).call
    expect(environment).to have_received(:invoke)
    expect(extractor).to have_received(:extract_all)
    expect(extractor).not_to have_received(:extract_changed)
    expect(Woods::RakeHelpers).to have_received(:woods_with_extraction_lock).with('/application/tmp/woods')
  end

  it 'uses full extraction for supplied removals and moves, including the last runtime class' do
    %w[delete move].each do |operation|
      refresh([{ path: 'app/controllers/last_controller.rb', operation: operation }]).call
    end
    expect(extractor).to have_received(:extract_all).twice
  end

  it 'defers an active daemon without booting Rails or acknowledging work' do
    allow(Woods::RakeHelpers).to receive(:woods_daemon_coverage).and_return(:running)
    expect { refresh([{ path: 'app/services/pay.rb', operation: 'update' }]).call }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(75) }
    expect(environment).not_to have_received(:invoke)
    expect(extractor).not_to have_received(:extract_changed)
  end

  it 'processes work when a daemon is degraded' do
    allow(Woods::RakeHelpers).to receive(:woods_daemon_coverage).and_return(:degraded)
    refresh([{ path: 'app/services/pay.rb', operation: 'update' }]).call
    expect(extractor).to have_received(:extract_changed).with(['app/services/pay.rb'])
  end

  it 'propagates publication failure rather than acknowledging the batch' do
    allow(extractor).to receive(:raise_on_publication_failure!).and_raise(Woods::ExtractionError, 'failed')
    expect { refresh([{ path: 'app/services/pay.rb', operation: 'update' }]).call }
      .to raise_error(Woods::ExtractionError)
  end

  it 'acknowledges a supported but now irrelevant input without publishing' do
    refresh([{ path: 'docs/readme.md', operation: 'update' }]).call
    expect(extractor).not_to have_received(:extract_changed)
  end

  it 'rejects malformed, oversized, foreign and unsupported event records' do
    expect { described_class.new('bad!') }.to raise_error(ArgumentError)
    expect { described_class.new('a' * 300_000) }.to raise_error(ArgumentError)
    ['', '/etc/passwd', '../secret', 'app/../secret', "app/x\0.rb"].each do |path|
      expect { refresh([{ path: path, operation: 'update' }]) }.to raise_error(ArgumentError)
    end
    expect { refresh([{ path: 'app/x.rb', operation: 'unknown' }]) }.to raise_error(ArgumentError)
  end
end
