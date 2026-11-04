# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractor'

# Who may publish (#1004), one row per state of the writer lock at the moment
# the run reaches its publish step:
#
# | lock at publish                | promotes | marker | prunes | own stage |
# |--------------------------------|----------|--------|--------|-----------|
# | held by this run               | yes      | yes    | yes    | promoted  |
# | taken over by another writer   | no       | no     | no     | removed   |
# | lock file unreadable (unknown) | no       | no     | no     | removed   |
# | no lock held: takes it itself  | yes      | yes    | yes    | promoted  |
# | no lock held, another holds it | no       | no     | no     | removed   |
RSpec.describe Woods::Extractor, 'writer fence' do
  let(:output) { Dir.mktmpdir('woods-writer-fence') }
  let(:store) { Woods::PayloadStore.new(output) }
  let(:lock_path) { File.join(output, 'extraction.lock') }

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(output), logger: double('Logger').as_null_object))
    payload = store.path_for(1)
    FileUtils.mkdir_p(payload)
    File.write(payload.join('manifest.json'), '{"generation":1}')
    Woods::Generation.new(output_dir: output).bump!(reason: 'baseline', payload: Woods::PayloadStore.name_for(1))
  end

  after do
    @lock&.release
    FileUtils.rm_rf(output)
  end

  def hold_lock
    @lock = Woods::Coordination::PipelineLock.for_index(output)
    raise 'could not take the lock' unless @lock.acquire

    @lock
  end

  def take_over!
    old = Time.now - 3600
    File.utime(old, old, lock_path)
    successor = Woods::Coordination::PipelineLock.for_index(output)
    raise 'takeover failed' unless successor.acquire

    successor
  end

  def staged_run
    extractor = described_class.new(output_dir: output)
    extractor.send(:begin_payload!)
    Woods::AtomicFile.write(extractor.payload_dir.join('manifest.json'), '{"generation":2}')
    extractor
  end

  def stages
    Dir.children(store.root).grep(/\A\.stage-/)
  end

  def marker_number
    Woods::Generation.new(output_dir: output).current.number
  end

  it 'publishes from a private stage while this run holds the lock' do
    hold_lock
    extractor = staged_run
    expect(extractor.payload_dir.basename.to_s).to eq(".stage-2-#{@lock.token}")

    expect(extractor.send(:publish_generation, 'full').number).to eq(2)
    expect(File.read(store.path_for(2).join('manifest.json'))).to eq('{"generation":2}')
    expect(stages).to be_empty
  end

  context 'when another writer took the lock over before publication' do
    it 'promotes, publishes and prunes nothing, and removes only its own stage' do
      hold_lock
      extractor = staged_run
      successor = take_over!
      theirs = store.create_stage(2, successor.token)
      allow(store).to receive(:prune)
      extractor.instance_variable_set(:@payload_store, store)

      expect(extractor.send(:publish_generation, 'full')).to be_nil
      expect { extractor.raise_on_publication_failure! }.to raise_error(Woods::ExtractionError, /no longer held/)
      expect(marker_number).to eq(1)
      expect(store.path_for(2)).not_to exist
      expect(store).not_to have_received(:prune)
      expect(stages).to eq([theirs.basename.to_s])
    ensure
      successor&.release
    end
  end

  it 'refuses to publish when the lock file cannot be read' do
    hold_lock
    extractor = staged_run
    File.write(lock_path, '{torn')

    expect(extractor.send(:publish_generation, 'full')).to be_nil
    expect(marker_number).to eq(1)
    expect(stages).to be_empty
  end

  # A direct library call (`Extractor#refresh` from a console) holds no lock.
  # It takes the index writer lock for its publish, so the number check and
  # the promotion are serialized against every locked writer.
  context 'when this process holds no writer lock' do
    around do |example|
      original = ENV.fetch('WOODS_LOCK_WAIT', nil)
      ENV['WOODS_LOCK_WAIT'] = '0.3'
      example.run
    ensure
      ENV['WOODS_LOCK_WAIT'] = original
    end

    it 'takes the index writer lock for its publish, and releases it' do
      extractor = staged_run
      fence_held = nil
      Woods::PublicationSeam.hook = lambda do |point, _dir|
        next unless point == :number_checked

        fence_held = File.exist?(lock_path)
      end

      expect(extractor.send(:publish_generation, 'full').number).to eq(2)
      expect(fence_held).to be(true)
      expect(File.exist?(lock_path)).to be(false)
      expect(stages).to be_empty
    ensure
      Woods::PublicationSeam.hook = nil
    end

    it 'refuses to publish while another writer holds the lock' do
      extractor = staged_run
      other = Woods::Coordination::PipelineLock.for_index(output)
      fork_holder = fork do
        other.acquire
        sleep
      end
      sleep 0.05 until File.exist?(lock_path)

      expect(extractor.send(:publish_generation, 'refresh:models')).to be_nil
      expect { extractor.raise_on_publication_failure! }
        .to raise_error(Woods::ExtractionError, /Could not take the index writer lock/)
      expect(marker_number).to eq(1)
      expect(store.path_for(2)).not_to exist
      expect(stages).to be_empty
    ensure
      if fork_holder
        Process.kill('KILL', fork_holder)
        Process.wait(fork_holder)
      end
    end
  end

  it 'refuses to publish when the lock was taken over and then released' do
    hold_lock
    take_over!.release
    extractor = described_class.new(output_dir: output)
    extractor.send(:begin_payload!)

    expect(extractor.send(:publish_generation, 'full')).to be_nil
    expect(marker_number).to eq(1)
  end

  it 'sweeps an abandoned stage only while it holds the lock' do
    abandoned = store.create_stage(1, 'crashed')
    old = Time.now - Woods::PayloadStore::ABANDONED_STAGE_AGE - 60
    File.utime(old, old, abandoned.to_s)

    staged_run.send(:publish_generation, 'full')
    expect(abandoned).to be_directory

    hold_lock
    staged_run.send(:publish_generation, 'full')
    expect(abandoned).not_to exist
  end

  it 'removes its stage when an incremental run publishes nothing' do
    hold_lock
    extractor = described_class.new(output_dir: output)
    staged = nil
    allow(extractor).to receive(:perform_extract_changed) do
      extractor.send(:begin_payload!, strict: true)
      staged = extractor.payload_dir
      []
    end

    extractor.extract_changed(['app/models/post.rb'])

    expect(staged.basename.to_s).to start_with('.stage-2-')
    expect(staged).not_to exist
    expect(stages).to be_empty
    expect(store.path_for(1)).to be_directory
  end

  # The snapshot store is shared state too: only a writer that still owns the
  # lock after publishing writes it.
  describe 'snapshot capture after publication' do
    it 'captures while this run still holds the lock' do
      hold_lock
      extractor = described_class.new(output_dir: output)
      allow(extractor).to receive(:capture_snapshot)

      extractor.send(:capture_published_snapshot)

      expect(extractor).to have_received(:capture_snapshot)
    end

    it 'skips the capture once the lock was taken over' do
      hold_lock
      extractor = staged_run
      successor = take_over!
      allow(extractor).to receive(:capture_snapshot)

      extractor.send(:capture_published_snapshot)

      expect(extractor).not_to have_received(:capture_snapshot)
    ensure
      successor&.release
    end

    it 'captures under a lock it takes itself when this process holds none' do
      extractor = described_class.new(output_dir: output)
      allow(extractor).to receive(:capture_snapshot)

      extractor.send(:capture_published_snapshot)

      expect(extractor).to have_received(:capture_snapshot)
    end
  end

  # A lock held for one directory while writing another must not quietly
  # leave the publish unfenced.
  describe 'a writer lock held for another directory' do
    let(:other) { Dir.mktmpdir('woods-writer-fence-other') }

    after { FileUtils.rm_rf(other) }

    it 'refuses to stage' do
      @lock = Woods::Coordination::PipelineLock.for_index(other)
      @lock.acquire

      expect { described_class.new(output_dir: output).send(:begin_payload!) }
        .to raise_error(Woods::ExtractionError, /writer lock for .* but is writing/)
      expect(stages).to be_empty
    end

    it 'ignores a registered lock that this process no longer owns' do
      @lock = Woods::Coordination::PipelineLock.for_index(other)
      @lock.acquire
      FileUtils.rm_f(File.join(other, 'extraction.lock'))

      expect(staged_run.send(:publish_generation, 'full').number).to eq(2)
    end
  end
end
