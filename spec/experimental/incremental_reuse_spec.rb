# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods/extractor'
require 'woods/experimental/incremental_reuse'

RSpec.describe Woods::Experimental::IncrementalReuse do
  include_context 'isolated Woods runtime'

  around do |example|
    previous = ENV.fetch('WOODS_EXPERIMENTAL_INCREMENTAL_REUSE', nil)
    Dir.mktmpdir('woods-reuse-spec') do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  ensure
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = previous
    described_class.reset!
  end

  before do
    stub_const('Rails', double('Rails', root: @root))
    Woods.configuration.concurrent_extraction = false
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = 'combined'
    @extractor = Woods::Extractor.new(output_dir: @root)
  end

  def marker(number, token)
    File.write(@root.join('generation.json'),
               JSON.generate(number: number, token: token, payload: "payloads/gen-#{number}"))
    [number, token, "payloads/gen-#{number}"]
  end

  it 'keeps the ordinary path disabled by default' do
    ENV.delete('WOODS_EXPERIMENTAL_INCREMENTAL_REUSE')
    result = described_class.run(@extractor) do |context|
      expect(context).to be_nil
      :ordinary
    end
    expect(result).to eq(:ordinary)
    expect(described_class.current).to be_nil
  end

  it 'falls back to ordinary extraction for concurrent configuration' do
    Woods.configuration.concurrent_extraction = true
    described_class.run(@extractor) { |context| expect(context).to be_nil }
  end

  it 'reuses one process-local session only while its published marker matches' do
    marker(1, 'first')
    session = nil
    described_class.run(@extractor) do |context|
      session = context.session
      session.graph = :old
    end
    described_class.run(Woods::Extractor.new(output_dir: @root)) { |context| expect(context.session.graph).to eq(:old) }
    marker(2, 'other-writer')
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
  end

  it 'accepts a pending graph only after this writer publishes the current token' do
    marker(1, 'first')
    described_class.run(@extractor) do |context|
      context.pending_graph = :new
      context.published_marker = marker(2, 'ours')
    end
    described_class.run(@extractor) { |context| expect(context.session.graph).to eq(:new) }
  end

  it 'drops pending facts when another writer publishes after this writer' do
    described_class.run(@extractor) do |context|
      context.pending_graph = :wrong
      context.published_marker = marker(2, 'ours')
      marker(3, 'theirs')
    end
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
  end

  it 'preserves application exception identity/backtrace and clears failed state' do
    error = IOError.new('application failure')
    error.set_backtrace(['application.rb:17'])
    expect do
      described_class.run(@extractor) do |context|
        context.session.graph = :unpublished
        raise error
      end
    end.to(raise_error do |caught|
             expect(caught).to equal(error)
             expect(caught.backtrace).to eq(['application.rb:17'])
           end)
    expect(described_class.current).to be_nil
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
  end

  it 'invalidates suppressed publication failures without changing their return' do
    result = described_class.run(@extractor) do |context|
      context.session.graph = :unpublished
      @extractor.instance_variable_set(:@publication_error, IOError.new('marker failed'))
      :original_return
    end
    expect(result).to eq(:original_return)
    @extractor.instance_variable_set(:@publication_error, nil)
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
  end

  it 'invalidates on mode changes and keeps graph-only free of template caching' do
    described_class.run(@extractor) { |context| context.session.graph = :old }
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = 'graph'
    described_class.run(@extractor) do |context|
      expect(context.session.graph).to be_nil
      expect(described_class.template_cache).to be_nil
    end
  end

  it 'does not leak context to worker threads or outside an operation' do
    described_class.run(@extractor) { expect(Thread.new { described_class.current }.value).to be_nil }
    expect(described_class.current).to be_nil
  end

  it 'rejects nested pilot extraction before running the nested body' do
    described_class.run(@extractor) do
      expect do
        described_class.run(@extractor) do
          raise 'must not run'
        end
      end.to raise_error(Woods::ExtractionError, /nested/)
    end
  end

  it 'serializes enabled operations without sharing their thread context' do
    entered = Queue.new
    release = Queue.new
    starting = Queue.new
    events = []
    first = Thread.new do
      described_class.run(@extractor) do
        events << :first_entered
        entered << true
        release.pop
        events << :first_left
      end
    end
    entered.pop
    second = Thread.new do
      starting << true
      described_class.run(@extractor) { events << :second_entered }
    end
    starting.pop
    release << true
    [first, second].each(&:value)
    expect(events).to eq(%i[first_entered first_left second_entered])
    expect(described_class.current).to be_nil
  end

  it 'invalidates sessions after a fork instead of inheriting locks or cached facts' do
    described_class.run(@extractor) { |context| context.session.graph = :parent }
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
  end

  it 'invalidates on application root and output changes' do
    described_class.run(@extractor) { |context| context.session.graph = :old }
    another = @root.join('another')
    FileUtils.mkdir_p(another)
    allow(Rails).to receive(:root).and_return(another)
    described_class.run(@extractor) { |context| expect(context.session.graph).to be_nil }
    described_class.run(@extractor) { |context| context.session.graph = :new }
    described_class.run(Woods::Extractor.new(output_dir: another)) do |context|
      expect(context.session.graph).to be_nil
    end
  end

  it 'refuses invalid modes and reset during an active operation' do
    described_class.run(@extractor) do
      expect { described_class.reset! }.to raise_error(Woods::ExtractionError, /between operations/)
    end
    ENV['WOODS_EXPERIMENTAL_INCREMENTAL_REUSE'] = 'typo'
    expect { described_class.run(@extractor) { :must_not_run } }.to raise_error(ArgumentError, /must be/)
  end

  it 'returns owned statistics without source payloads' do
    described_class.run(@extractor) { |context| context.session.counts[:graph_reused] += 1 }
    stats = described_class.stats
    stats[:counts][:graph_reused] = 99
    expect(described_class.stats[:counts][:graph_reused]).to eq(1)
    expect(stats.keys).to contain_exactly(:mode, :generation, :counts, :templates)
  end
end
