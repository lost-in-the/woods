# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/generated_job_site'

RSpec.describe Woods::Extractors::GeneratedJobSite do
  let(:app_root) { File.realpath(Dir.mktmpdir('generated_job_site')) }
  let(:resolver) { described_class.new(app_root: app_root) }

  after do
    %i[GjsWidget GjsLedger GjsShipment GjsAsync GjsLooseWorker].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    FileUtils.rm_rf(app_root)
  end

  def write(relative, source)
    path = File.join(app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def load_generator
    load write('lib/gjs_async.rb', <<~RUBY)
      module GjsAsync
        def async_method(name, queue: nil)
          klass = Class.new do
            def perform(id); end
          end
          const_set("\#{name.to_s.split('_').map(&:capitalize).join}Worker", klass)
        end
      end
    RUBY
  end

  it 'resolves the owner line that calls the generator, and names the generator' do
    load_generator
    model = write('app/models/gjs_widget.rb', <<~RUBY)
      class GjsWidget
        extend GjsAsync

        async_method :sync
        async_method :sync_now
      end
    RUBY
    load model

    site = resolver.call(GjsWidget::SyncNowWorker)

    expect(site.to_h).to eq(file_path: model, line: 5, source: "  async_method :sync_now\n",
                            generated_by: 'async_method')
    expect(resolver.call(GjsWidget::SyncWorker).line).to eq(4)
  end

  it 'keeps the lines of a multi-line call up to its arguments, without a block body' do
    load_generator
    model = write('app/models/gjs_ledger.rb', <<~RUBY)
      class GjsLedger
        extend GjsAsync
        async_method :settle,
                     queue: :low do
          raise 'never part of the unit'
        end
      end
    RUBY
    load model

    site = resolver.call(GjsLedger::SettleWorker)

    expect(site.source).to eq("  async_method :settle,\n               queue: :low do\n")
    expect(site.line).to eq(3)
  end

  it 'falls back to the generator line when the owner file has no matching call' do
    generator = load_generator
    load write('app/models/gjs_shipment.rb', <<~RUBY)
      class GjsShipment
        extend GjsAsync
        %i[dispatch].each { |name| send(:async_method, name) }
      end
    RUBY

    site = resolver.call(GjsShipment::DispatchWorker)

    expect(site.file_path).to eq(File.join(app_root, 'lib/gjs_async.rb'))
    expect(site.line).to eq(6)
    expect(site.source).to include('const_set(')
    expect(site.source.lines.size).to eq(1)
    expect(site.generated_by).to eq('async_method')
    expect(generator).to be(true)
  end

  it 'uses the defining line itself when no method encloses it' do
    path = write('app/workers/gjs_loose_worker.rb', <<~RUBY)
      GjsLooseWorker = Class.new do
        def perform; end
      end
    RUBY
    load path

    site = resolver.call(GjsLooseWorker)

    expect(site.to_h).to eq(file_path: path, line: 1, source: "GjsLooseWorker = Class.new do\n", generated_by: nil)
  end

  it 'is nil for a class its file declares, an anonymous class, and a class defined outside the application' do
    path = write('app/workers/gjs_widget.rb', "class GjsWidget\n  def perform; end\nend\n")
    load path

    expect(resolver.call(GjsWidget)).to be_nil
    expect(resolver.call(Class.new)).to be_nil
    expect(resolver.call(String)).to be_nil
    expect(described_class.new(app_root: File.join(app_root, 'elsewhere')).call(GjsWidget)).to be_nil
  end

  it 'is nil when the generator lives under vendor' do
    load write('vendor/gems/gjs_async.rb', <<~RUBY)
      module GjsAsync
        def async_method(name) = const_set("\#{name.to_s.capitalize}Worker", Class.new)
      end
    RUBY
    load write('app/models/gjs_widget.rb', "class GjsWidget\n  extend GjsAsync\n  async_method :sync\nend\n")

    expect(resolver.call(GjsWidget::SyncWorker)).to be_nil
  end

  it 'does not match a generator argument that is only a prefix of another word' do
    load_generator
    load write('app/models/gjs_widget.rb', <<~RUBY)
      class GjsWidget
        extend GjsAsync
        async_method :sync
        send(:async_method, :synchronize)
      end
    RUBY

    expect(resolver.call(GjsWidget::SynchronizeWorker).file_path).to end_with('lib/gjs_async.rb')
  end

  it 'answers a file with 10k near-matching generator calls quickly' do
    load_generator
    calls = (1..10_000).map { |i| "  async_method :sync_#{i}x if false\n" }.join
    load write('app/models/gjs_widget.rb',
               "class GjsWidget\n  extend GjsAsync\n#{calls}  async_method :sync_now\nend\n")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    site = resolver.call(GjsWidget::SyncNowWorker)

    expect(site.line).to eq(10_003)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end
end
