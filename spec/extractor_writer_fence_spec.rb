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
#
# A stage belongs to one run, never to a lock: two runs that find the same
# held lock still stage apart, and the one that publishes second is refused.
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
    expect(extractor.payload_dir.basename.to_s).to start_with(".stage-2-#{@lock.token}-")

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

  # Two runs in one process that both find the held writer lock: a direct
  # library call beside a locked writer. Each stages apart; the first to
  # publish wins with exactly its own files and the other is refused at the
  # generation-number check, its stage removed.
  describe 'two runs in one process under one held lock' do
    def stage_files(extractor, owner)
      Woods::AtomicFile.write(extractor.payload_dir.join('manifest.json'), JSON.generate(owner: owner))
      Woods::AtomicFile.write(extractor.payload_dir.join("#{owner}.json"), '{}')
    end

    def live_files
      dir = Woods::Generation.new(output_dir: output).payload_dir
      Dir.children(dir.to_s).sort.to_h { |name| [name, File.read(dir.join(name))] }
    end

    let(:runs) do
      hold_lock
      first = described_class.new(output_dir: output)
      first.send(:begin_payload!)
      Woods::AtomicFile.write(first.payload_dir.join('early.json'), '{}')
      second = described_class.new(output_dir: output)
      second.send(:begin_payload!)
      stage_files(first, 'first')
      stage_files(second, 'second')
      { 'first' => first, 'second' => second }
    end

    it 'gives each run its own stage, so neither empties the other' do
      first, second = runs.values_at('first', 'second')

      expect(first.payload_dir).not_to eq(second.payload_dir)
      expect(first.payload_dir.join('early.json')).to exist
      expect(stages.size).to eq(2)
    end

    {
      'first' => %w[early.json first.json manifest.json],
      'second' => %w[manifest.json second.json]
    }.each do |winner, expected|
      it "publishes only the #{winner} run's files and refuses the other when the #{winner} publishes first" do
        loser = (runs.keys - [winner]).first

        expect(runs.fetch(winner).send(:publish_generation, 'full').number).to eq(2)
        published = live_files
        expect(published.keys).to eq(expected)
        expect(JSON.parse(published.fetch('manifest.json'))).to eq('owner' => winner)

        expect(runs.fetch(loser).send(:publish_generation, 'full')).to be_nil
        expect { runs.fetch(loser).raise_on_publication_failure! }
          .to raise_error(Woods::ExtractionError, /generation moved to 2/)
        expect(marker_number).to eq(2)
        expect(live_files).to eq(published)
        expect(stages).to be_empty
      end
    end

    # The pipeline_extract handoff: the request thread takes the lock and a
    # worker thread runs the extraction, which must publish under it.
    it 'publishes under a lock another thread of this process acquired' do
      hold_lock
      original = ENV.fetch('WOODS_LOCK_WAIT', nil)
      ENV['WOODS_LOCK_WAIT'] = '0.3'
      published = Thread.new { staged_run.send(:publish_generation, 'full') }.value

      expect(published.number).to eq(2)
      expect(File.exist?(lock_path)).to be(true)
    ensure
      ENV['WOODS_LOCK_WAIT'] = original
    end
  end

  # A child forked while the parent holds the lock inherits the registry entry
  # but not the ownership: its run stages under its own name and takes the lock
  # for itself, which the living parent still holds.
  it 'refuses a forked child the parent\'s lock for staging or publishing', if: Process.respond_to?(:fork) do
    hold_lock
    reader, writer = IO.pipe
    child = fork do
      reader.close
      writer.write(JSON.generate(child_run_outcome))
    ensure
      exit!(0)
    end
    writer.close
    result = JSON.parse(reader.read)
    Process.wait(child)

    expect(result['stage']).to start_with('.stage-2-')
    expect(result['stage']).not_to include(@lock.token)
    expect(result['error']).to match(/Could not take the index writer lock/)
    expect(marker_number).to eq(1)
    expect(@lock.fenced { :ours }).to eq(:ours)
  end

  # @return [Hash] the stage a run in this process opened and why its publish failed
  def child_run_outcome
    ENV['WOODS_LOCK_WAIT'] = '0.3'
    run = staged_run
    stage = run.payload_dir.basename.to_s
    run.send(:publish_generation, 'full')
    run.raise_on_publication_failure!
    { stage: stage, error: nil }
  rescue Woods::ExtractionError => e
    { stage: stage, error: e.message }
  end

  # A child forked in the middle of a run inherits the extractor, its open
  # stage and the caller's lock, and unwinds the same ensure blocks the
  # parent will: the run's stage cleanup and with_lock's release. Both belong
  # to the parent. On the way out the child also tries to publish the
  # inherited run, whose refusal cleans up the stage too.
  describe 'a child forked while a run is staged', if: Process.respond_to?(:fork) do
    { 'returns normally' => :return, 'raises' => :raise, 'calls exit!' => :exit! }.each do |exit_kind, mode|
      it "leaves the parent's stage and lock alone when the child #{exit_kind}, and the parent still cleans up" do
        lock = Woods::Coordination::PipelineLock.for_index(output)
        extractor = described_class.new(output_dir: output)
        seen = {}
        allow(extractor).to receive(:perform_extract_all) do
          seen.merge!(fork_during_stage(extractor, lock) { leave_child(extractor, mode) })
        end

        unwind_once_in_child { lock.with_lock { extractor.extract_all } }

        expect(seen).to eq(stage_kept: true, lock_kept: true, fence: :ours, stages: 1)
        expect(stages).to be_empty
        expect(File.exist?(lock_path)).to be(false)
      end
    end

    it "keeps the parent's stage when the child reopens the inherited run" do
      lock = Woods::Coordination::PipelineLock.for_index(output)
      extractor = described_class.new(output_dir: output)
      seen = {}
      allow(extractor).to receive(:perform_extract_all) do
        seen.merge!(fork_during_stage(extractor, lock) { reopen_in_child(extractor) })
      end

      unwind_once_in_child { lock.with_lock { extractor.extract_all } }

      expect(seen).to eq(stage_kept: true, lock_kept: true, fence: :ours, stages: 1)
      expect(stages).to be_empty
    end

    # Stages a run, forks, and in the parent reports what the child left.
    def fork_during_stage(extractor, lock)
      extractor.send(:begin_payload!)
      stage = extractor.payload_dir
      Woods::AtomicFile.write(stage.join('parent.json'), '{}')
      child = fork
      if child.nil?
        @forked_child = true
        return yield
      end

      Process.wait(child)
      { stage_kept: stage.join('parent.json').file?, lock_kept: File.exist?(lock_path),
        fence: lock.fenced { :ours }, stages: stages.size }
    end

    def leave_child(extractor, mode)
      ENV['WOODS_LOCK_WAIT'] = '0.3'
      extractor.send(:publish_generation, 'full')
      exit!(0) if mode == :exit!
      raise 'the child failed' if mode == :raise

      {}
    end

    # The child opens a stage of its own on the inherited instance, cannot
    # publish it while the parent holds the lock, and removes it.
    def reopen_in_child(extractor)
      ENV['WOODS_LOCK_WAIT'] = '0.3'
      extractor.send(:begin_payload!)
      extractor.send(:publish_generation, 'full')
      {}
    end

    # The child unwinds the run like the parent, then stops before RSpec's
    # own cleanup can remove the output directory under the parent.
    def unwind_once_in_child
      yield
    rescue RuntimeError
      raise unless @forked_child
    ensure
      exit!(0) if @forked_child
    end
  end
end
