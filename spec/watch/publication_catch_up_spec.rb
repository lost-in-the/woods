# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'timeout'
require 'woods/extractor'
require 'woods/watch/daemon'

RSpec.describe 'Watcher reconciliation across publication' do
  let(:root) { Dir.mktmpdir('woods-publication-root') }
  let(:index_root) { Dir.mktmpdir('woods-publication-index') }
  let(:source) { File.join(root, 'app/views/posts/show.html.erb') }
  let(:clock) { Time.at(1_790_000_000.75) }
  let(:generation) { Woods::Generation.new(output_dir: index_root) }
  let(:consumer) { instance_spy(Woods::Extractor) }

  before do
    stub_const('Rails', double(root: Pathname.new(root), logger: double.as_null_object))
    allow(Time).to receive(:now).and_return(clock)
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, 'before')
    stamp_source(clock.to_i - 10)
    allow(consumer).to receive(:extract_changed) { prepare.send(:publish_generation, 'incremental') && ['view'] }
    allow(consumer).to receive(:extract_all) { prepare.send(:publish_generation, 'full') && {} }
  end

  after { FileUtils.rm_rf([root, index_root]) }

  def stamp_source(seconds)
    File.utime(Time.at(seconds), Time.at(seconds), source)
  end

  def prepare
    extractor = Woods::Extractor.new(output_dir: index_root)
    extractor.send(:begin_source_inputs, 'full')
    extractor.send(:begin_payload!)
    extractor.instance_variable_set(:@eager_load_complete, true)
    extractor
  end

  def manifest_path
    generation.payload_dir.join('source_inputs.json')
  end

  def manifest
    JSON.parse(File.read(manifest_path))
  end

  def rewrite_manifest
    data = manifest
    yield data
    File.write(manifest_path, JSON.generate(data))
  end

  def daemon
    watcher = double(start: nil, stop: nil)
    Woods::Watch::Daemon.new(root: root, output_dir: index_root, watcher: watcher, debounce: 0,
                             extractor_factory: -> { consumer },
                             reloader: double(enabled?: true, reload!: true),
                             boot_snapshot: Woods::Watch::BootSnapshot.new(root: root))
  end

  # The writer cannot proceed until the edit has landed; no scheduler sleeps
  # or filesystem timestamp resolution assumptions establish the ordering.
  def publish_with_edit(extractor, boundary, mtime: clock.to_i)
    arrived = Queue.new
    resume = Queue.new
    allow(extractor).to receive(boundary).and_wrap_original do |method, *args|
      arrived << true
      resume.pop
      method.call(*args)
    end
    writer = Thread.new { extractor.send(:publish_generation, 'full') }
    Timeout.timeout(5) { arrived.pop }
    File.write(source, 'edited during publication')
    stamp_source(mtime)
    resume << true
    Timeout.timeout(5) { writer.value }
  ensure
    resume << true
    writer&.join(5) || writer&.kill&.join
  end

  %i[write_source_inputs sync_payload].each do |boundary|
    it "catches a whole-second edit at #{boundary} before the publication marker" do
      extractor = prepare
      expect(publish_with_edit(extractor, boundary)).not_to be_nil
      expect(generation.current.number).to eq(1)
      expect(File.mtime(source)).to be < File.mtime(generation.path)
      expect(manifest.fetch('errors').any? { |error| error['reason'] == 'source_changed_during_extraction' })
        .to be(boundary == :write_source_inputs)

      expect(daemon.run).to eq(:stopped)

      expect(consumer).to have_received(:extract_changed).with([source]).once
      expect(generation.current.number).to eq(2)
      daemon.run
      expect(consumer).to have_received(:extract_changed).once
      expect(consumer).not_to have_received(:extract_all)
    end
  end

  it 'uses recorded dirty paths even when an editor restores an older mtime' do
    publish_with_edit(prepare, :write_source_inputs, mtime: clock.to_i - 10)

    daemon.run

    expect(consumer).to have_received(:extract_changed).with([source])
  end

  it 'uses an oversized manifest capture boundary without repeating catch-up or forcing full extraction' do
    stamp_source(clock.to_i)
    extractor = prepare
    extractor.instance_variable_get(:@source_inputs).instance_variable_get(:@snapshot)['metrics']['padding'] =
      'x' * 4000
    stub_const('Woods::SourceInputs::Manifest::MAX_BYTES', 2000)
    extractor.send(:publish_generation, 'full')
    expect(manifest['state']).to eq('unavailable')

    expect { 2.times { daemon.run } }
      .to output(/source freshness unavailable.*source_manifest_too_large.*bytes.*limit 2000/).to_stderr
    expect(consumer).not_to have_received(:extract_changed)
    expect(consumer).not_to have_received(:extract_all)

    File.write(source, 'changed after unavailable publication')
    stamp_source(clock.to_i)
    2.times { daemon.run }
    expect(consumer).to have_received(:extract_changed).with([source]).once
    expect(consumer).not_to have_received(:extract_all)
  end

  it 'does not re-extract unchanged inputs in the capture second' do
    stamp_source(clock.to_i)
    prepare.send(:publish_generation, 'full')

    2.times { daemon.run }

    expect(consumer).not_to have_received(:extract_changed)
    expect(consumer).not_to have_received(:extract_all)
  end

  it 'keeps reference-bearing instability refused and the previous generation active' do
    prepare.send(:publish_generation, 'full')
    token = generation.current.token
    extractor = prepare
    extractor.instance_variable_set(:@source_reference_paths, Set.new([source]))

    expect(publish_with_edit(extractor, :write_source_inputs)).to be_nil
    expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError)
    expect(generation.current.token).to eq(token)
    daemon.run
    expect(consumer).to have_received(:extract_changed).with([source])
  end

  it 'keeps unchanged reference-bearing publication eligible to stand down' do
    stamp_source(clock.to_i)
    extractor = prepare
    extractor.instance_variable_set(:@source_reference_paths, Set.new([source]))
    expect(extractor.send(:publish_generation, 'full')).not_to be_nil

    daemon.run

    expect(consumer).not_to have_received(:extract_changed)
    expect(consumer).not_to have_received(:extract_all)
  end

  [nil, 'yesterday', -1, 1_990_000_000].each do |invalid|
    it "reconciles a missing or invalid legacy capture boundary #{invalid.inspect} only once" do
      prepare.send(:publish_generation, 'full')
      rewrite_manifest { |data| data['captured_at'] = invalid }

      2.times { daemon.run }

      expect(consumer).to have_received(:extract_all).once
      expect(consumer).not_to have_received(:extract_changed)
    end
  end

  { 'root' => '/another/app', 'generation' => 90, 'key_id' => '0' * 64, 'rules' => '0' * 64 }.each do |field, invalid|
    it "does not trust a source manifest with a mismatched #{field}" do
      prepare.send(:publish_generation, 'full')
      rewrite_manifest { |data| data[field] = invalid }

      daemon.run

      expect(consumer).to have_received(:extract_all).once
    end
  end

  it 'accepts the legacy manifest format but reconciles its absent optional timestamp once' do
    prepare.send(:publish_generation, 'full')
    rewrite_manifest { |data| data.delete('captured_at') }
    expect { Woods::SourceInputs::Manifest.parse(File.read(manifest_path)) }.not_to raise_error

    2.times { daemon.run }

    expect(consumer).to have_received(:extract_all).once
  end

  it 'keeps a recent changed path uncovered when the bounded content scan cannot read it' do
    prepare.send(:publish_generation, 'full')
    File.write(source, 'changed')
    stamp_source(clock.to_i)
    scan = Woods::Watch::CatchUp.new(root: root, output_dir: index_root, ignored: [])
    allow(scan).to receive(:current_identities).and_return({})

    expect(scan.paths).to include(source)
  end

  it 'does not accept a matching sibling consumer as proof of all retained facts' do
    prepare.send(:publish_generation, 'full')
    File.write(source, 'changed')
    stamp_source(clock.to_i)
    rewrite_manifest do |data|
      data['identities'] << OpenSSL::HMAC.hexdigest('SHA256',
                                                    Woods::SourceInputs::PrivateKey.new(output_dir: index_root).bytes,
                                                    'changed')
      data['scopes']['unit:sibling'] = { 'app/views/posts/show.html.erb' => data['identities'].length - 1 }
    end

    expect(daemon.send(:uncovered_paths)).to include(source)
  end

  it 'reconciles an old index with no source manifest and no actionable paths only once' do
    File.unlink(source)
    prepare.send(:publish_generation, 'full')
    File.unlink(manifest_path)

    2.times { daemon.run }

    expect(consumer).to have_received(:extract_all).once
    expect(generation.current.number).to eq(2)
  end
end
