# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'woods/extractor'
require 'woods/published_index'
require 'woods/coordination/lock_heartbeat'
require 'woods/rake_helpers'
require 'woods/mcp/server'

# The race behind #1004, run for real with two processes.
#
# Writer A stops (SIGSTOP, so its heartbeat thread stops too: a laptop
# sleeping mid-run) at one named point on its publish path. Its lease is then
# expired. Writer B takes the lock over and publishes. A is resumed. Nothing
# A does after that may change what B published or what readers see.
#
# Each writer goes through the real lock, the real heartbeat, the real
# private stage, seeding from the published generation, and the real
# publish. The three publish shapes are the ones the entry points use: full
# (`begin_payload!` with rewritten families), incremental (`strict: true`,
# reason `incremental`) and refresh (`strict: true`, reason `refresh:<keys>`).
# The booted lane drives the entry points themselves
# (spec/integration/writer_fencing_booted_spec.rb).
module WriterFencingCases
  # The begin_payload! arguments and generation reason of each entry point.
  ENTRY_SHAPES = {
    full: { begin: { rewritten_dirs: [] }, reason: 'full' },
    incremental: { begin: { strict: true }, reason: 'incremental' },
    refresh: { begin: { strict: true }, reason: 'refresh:models' }
  }.freeze

  # Outside the fence: B can take the lock over while A is stopped here.
  TAKEOVER_POINTS = %i[staged before_promotion].freeze

  # Inside the fence: a takeover has to wait for A.
  FENCED_POINTS = %i[promoted marker_published].freeze
end

RSpec.describe 'Writer fencing across a lock takeover (#1004)',
               :aggregate_failures, if: RUBY_PLATFORM.include?('linux') && Process.respond_to?(:fork) do
  let(:unit_path) { 'models/Post_a5554622.json' }

  around do |example|
    Dir.mktmpdir('woods-fencing') do |root|
      @output = File.join(root, 'index')
      seed_baseline!
      example.run
    ensure
      Array(@children).each { |pid| reap(pid) }
    end
  end

  before do
    stub_const('Rails', double('Rails', root: Pathname.new(@output), logger: double('Logger').as_null_object))
    Woods::PublicationSeam.hook = nil
  end

  after { Woods::PublicationSeam.hook = nil }

  # Generation 1: the fixture index, published as a payload.
  def seed_baseline!
    payload = Woods::PayloadStore.new(@output).path_for(1)
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), payload)
    Woods::Generation.new(output_dir: @output).bump!(reason: 'baseline', payload: Woods::PayloadStore.name_for(1))
  end

  # One writer, in its own process. Exit 0: published. Exit 2: the run
  # reported a publication failure. Exit 3: could not take the lock.
  def spawn_writer(label, shape:, pause_at: nil, locked: true, wait: 10)
    ready = File.join(File.dirname(@output), "#{label}.paused")
    pid = fork do
      Woods::PublicationSeam.hook = lambda do |point, _dir|
        next unless point == pause_at

        File.write(ready, Woods::Coordination::PipelineLock.held_for_index(@output)&.token.to_s)
        Process.kill('STOP', Process.pid)
      end
      shape = WriterFencingCases::ENTRY_SHAPES.fetch(shape)
      exit!(locked ? write_and_publish(label, shape, wait: wait) : write_and_publish_unlocked(label, shape))
    end
    (@children ||= []) << pid
    [pid, ready]
  end

  def write_and_publish(label, shape, wait: 10)
    lock = Woods::Coordination::PipelineLock.for_index(@output)
    return 3 unless acquired_waiting?(lock, wait)

    begin
      Woods::Coordination::LockHeartbeat.run(lock, tick: 0.05) do
        extractor = Woods::Extractor.new(output_dir: @output)
        extractor.send(:begin_payload!, **shape[:begin])
        label_payload(extractor.payload_dir, label)
        extractor.send(:publish_generation, shape[:reason])
        extractor.raise_on_publication_failure!
      end
      0
    rescue Woods::ExtractionError
      2
    ensure
      lock.release
    end
  end

  # A direct library call, as `Extractor#refresh` from a console makes it:
  # no lock taken by the caller.
  def write_and_publish_unlocked(label, shape)
    extractor = Woods::Extractor.new(output_dir: @output)
    extractor.send(:begin_payload!, **shape[:begin])
    label_payload(extractor.payload_dir, label)
    extractor.send(:publish_generation, shape[:reason])
    extractor.raise_on_publication_failure!
    0
  rescue Woods::ExtractionError
    2
  end

  # What this writer changed: one unit and the manifest, both through
  # AtomicFile as every real writer does.
  def label_payload(payload, label)
    [unit_path, 'manifest.json'].each do |relative|
      data = JSON.parse(File.read(payload.join(relative))).merge('written_by' => label)
      Woods::AtomicFile.write(payload.join(relative), JSON.generate(data))
    end
  end

  # A contender that finds the guard held waits on it, as `woods:extract`
  # does; one that finds a fresh lock retries briefly.
  def acquired_waiting?(lock, wait = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    until lock.acquire
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    true
  end

  def wait_until(what, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # Paused means stopped by the kernel, not merely past the seam.
  def wait_stopped(pid, ready)
    wait_until('writer to pause') { File.exist?(ready) }
    wait_until('writer to stop') { File.read("/proc/#{pid}/stat")[/\) (\S)/, 1] == 'T' }
  end

  def lock_token_of(ready)
    File.read(ready)
  end

  def finish(pid)
    _, status = Process.wait2(pid)
    @children.delete(pid)
    status.exitstatus
  end

  def reap(pid)
    Process.kill('CONT', pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def expire_lease!
    lock_path = File.join(@output, 'extraction.lock')
    old = Time.now - Woods::Coordination::PipelineLock::INDEX_WRITER_STALE_TIMEOUT - 60
    File.utime(old, old, lock_path)
  end

  def guard_held?
    guard = File.join(@output, Woods::Coordination::PipelineLock.guard_filename('extraction'))
    return false unless File.exist?(guard)

    File.open(guard, File::RDWR) { |file| !file.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def marker
    Woods::Generation.new(output_dir: @output).current
  end

  def generation_dirs
    Dir.children(File.join(@output, 'payloads')).grep(/\Agen-\d+\z/).sort
  end

  def stages
    Dir.children(File.join(@output, 'payloads')).grep(/\A\.stage-/)
  end

  def tree_hashes(number)
    root = Woods::PayloadStore.new(@output).path_for(number)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root.to_s).sort.filter_map do |relative|
      path = root.join(relative)
      [relative, Digest::SHA256.file(path.to_s).hexdigest] if path.file?
    end.to_h
  end

  def reader_view(index)
    { generation: index.generation_number, unit: index.unit('Post'),
      writer: index.manifest['written_by'], units: index.units.map { |entry| entry['identifier'] }.sort }
  end

  describe 'the uncontested path' do
    WriterFencingCases::ENTRY_SHAPES.each_key do |shape|
      it "publishes a #{shape} run from a private stage and leaves no stage behind" do
        pid, = spawn_writer('solo', shape: shape)

        expect(finish(pid)).to eq(0)
        expect(marker.number).to eq(2)
        expect(marker.payload).to eq('payloads/gen-2')
        Woods::PublishedIndex.open(@output) do |index|
          expect(index.unit('Post')['written_by']).to eq('solo')
        end
        expect(stages).to be_empty
        expect(generation_dirs).to eq(%w[gen-1 gen-2])
      end
    end
  end

  WriterFencingCases::ENTRY_SHAPES.each_key do |shape|
    describe "a #{shape} writer resumed after a takeover" do
      WriterFencingCases::TAKEOVER_POINTS.each do |point|
        context "when it was paused at #{point}" do
          it 'changes nothing B published and nothing a reader sees, and fails its own run' do
            pinned = Woods::PublishedIndex.new(@output, generation: 1)
            pinned_before = reader_view(pinned)
            a, ready = spawn_writer('A', shape: shape, pause_at: point)
            wait_stopped(a, ready)

            expire_lease!
            b, = spawn_writer('B', shape: shape)
            expect(finish(b)).to eq(0)

            published = marker
            expect(published.number).to eq(2)
            b_hashes = tree_hashes(2)
            dirs = generation_dirs
            current = Woods::PublishedIndex.new(@output)
            current_before = reader_view(current)
            expect(current_before[:writer]).to eq('B')

            Process.kill('CONT', a)
            expect(finish(a)).to eq(2)

            expect(marker.to_h).to eq(published.to_h)
            expect(tree_hashes(2)).to eq(b_hashes)
            expect(generation_dirs).to eq(dirs)
            expect(reader_view(current)).to eq(current_before)
            expect(reader_view(pinned)).to eq(pinned_before)
            Woods::PublishedIndex.open(@output) { |fresh| expect(reader_view(fresh)).to eq(current_before) }
            expect(stages).to be_empty
          ensure
            pinned&.close
            current&.close
          end
        end
      end

      WriterFencingCases::FENCED_POINTS.each do |point|
        context "when it was paused at #{point}, inside the fence" do
          it 'holds off the takeover until A finishes, and then both publications stand' do
            pinned = Woods::PublishedIndex.new(@output, generation: 1)
            pinned_before = reader_view(pinned)
            a, ready = spawn_writer('A', shape: shape, pause_at: point)
            wait_stopped(a, ready)

            expire_lease!
            expect(guard_held?).to be(true)
            b, = spawn_writer('B', shape: shape)

            Process.kill('CONT', a)
            expect(finish(a)).to eq(0)
            expect(finish(b)).to eq(0)

            expect(marker.number).to eq(3)
            Woods::PublishedIndex.open(@output, generation: 2) do |index|
              expect(index.unit('Post')['written_by']).to eq('A')
            end
            Woods::PublishedIndex.open(@output) { |index| expect(index.unit('Post')['written_by']).to eq('B') }
            expect(reader_view(pinned)).to eq(pinned_before)
            expect(stages).to be_empty
          ensure
            pinned&.close
          end
        end
      end

      # B holds the lock but has not published when A resumes: the token
      # check at promotion is what stops A, not a moved generation number.
      context 'when it was paused at before_promotion and B has taken over but not published' do
        it 'refuses to publish, and B then publishes normally' do
          a, a_ready = spawn_writer('A', shape: shape, pause_at: :before_promotion)
          wait_stopped(a, a_ready)
          expire_lease!
          b, b_ready = spawn_writer('B', shape: shape, pause_at: :staged)
          wait_stopped(b, b_ready)
          b_stage = stages.find { |name| !name.end_with?(lock_token_of(a_ready)) }

          Process.kill('CONT', a)
          expect(finish(a)).to eq(2)
          expect(marker.number).to eq(1)
          expect(generation_dirs).to eq(%w[gen-1])
          expect(stages).to eq([b_stage])

          Process.kill('CONT', b)
          expect(finish(b)).to eq(0)
          expect(marker.number).to eq(2)
          Woods::PublishedIndex.open(@output) { |index| expect(index.unit('Post')['written_by']).to eq('B') }
          expect(stages).to be_empty
        end
      end

      context 'when it was paused after publishing' do
        it "leaves B's later publication alone" do
          a, ready = spawn_writer('A', shape: shape, pause_at: :published)
          wait_stopped(a, ready)
          expire_lease!
          b, = spawn_writer('B', shape: shape)
          expect(finish(b)).to eq(0)
          b_hashes = tree_hashes(3)
          published = marker

          Process.kill('CONT', a)
          expect(finish(a)).to eq(0)

          expect(marker.to_h).to eq(published.to_h)
          expect(tree_hashes(3)).to eq(b_hashes)
          expect(generation_dirs).to eq(%w[gen-1 gen-2 gen-3])
        end
      end
    end
  end

  # A direct `Extractor#refresh` (no lock held by its caller) must not be able
  # to confirm the next number, pause, and then promote over a generation a
  # locked writer published meanwhile.
  describe 'a direct refresh with no caller-held lock' do
    it 'serializes its number check and promotion against a locked writer' do
      direct, ready = spawn_writer('direct', shape: :refresh, pause_at: :number_checked, locked: false)
      wait_stopped(direct, ready)

      expect(guard_held?).to be(true)
      blocked, = spawn_writer('B', shape: :full, wait: 1)
      expect(finish(blocked)).to eq(3)
      expect(marker.number).to eq(1)

      Process.kill('CONT', direct)
      expect(finish(direct)).to eq(0)
      expect(marker.number).to eq(2)
      direct_hashes = tree_hashes(2)

      b, = spawn_writer('B', shape: :full)
      expect(finish(b)).to eq(0)

      expect(marker.number).to eq(3)
      expect(tree_hashes(2)).to eq(direct_hashes)
      Woods::PublishedIndex.open(@output, generation: 2) { |i| expect(i.unit('Post')['written_by']).to eq('direct') }
      Woods::PublishedIndex.open(@output) { |i| expect(i.unit('Post')['written_by']).to eq('B') }
      expect(stages).to be_empty
    end
  end

  # `woods:clean` deletes index entries one at a time, each inside the fence.
  describe 'woods:clean resumed after a takeover' do
    def spawn_clean(pause_at:)
      ready = File.join(File.dirname(@output), 'clean.paused')
      pid = fork do
        Woods::PublicationSeam.hook = lambda do |point, _dir|
          next unless point == pause_at && !File.exist?(ready)

          File.write(ready, 'clean')
          Process.kill('STOP', Process.pid)
        end
        Woods::RakeHelpers.woods_clean_index(@output, wait: 5)
        exit!(0)
      rescue Woods::Coordination::LockLostError
        exit!(2)
      end
      (@children ||= []) << pid
      [pid, ready]
    end

    it 'stops before deleting anything B published' do
      # Sorted first, so the clean pauses before it reaches the index proper.
      File.write(File.join(@output, 'a-scratch'), 'x')
      clean, ready = spawn_clean(pause_at: :swept_entry)
      wait_stopped(clean, ready)
      expect(File.exist?(File.join(@output, 'a-scratch'))).to be(false)

      expire_lease!
      b, = spawn_writer('B', shape: :full)
      expect(finish(b)).to eq(0)
      published = marker
      b_hashes = tree_hashes(published.number)

      Process.kill('CONT', clean)
      expect(finish(clean)).to eq(2)

      expect(marker.to_h).to eq(published.to_h)
      expect(tree_hashes(published.number)).to eq(b_hashes)
      Woods::PublishedIndex.open(@output) { |index| expect(index.unit('Post')['written_by']).to eq('B') }
    end

    it 'still cleans the whole index when uncontested' do
      clean, = spawn_clean(pause_at: nil)

      expect(finish(clean)).to eq(0)
      expect(Dir.children(@output).sort).to eq(['.extraction.lock.guard'])
    end
  end

  # A writer stopped inside the fence holds the guard. Contenders must give up
  # within their own deadline instead of blocking on the flock.
  describe 'contenders while a stopped writer holds the guard' do
    def elapsed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end

    it 'returns within each caller\'s deadline' do
      a, ready = spawn_writer('A', shape: :full, pause_at: :promoted)
      wait_stopped(a, ready)
      expire_lease!
      contender = Woods::Coordination::PipelineLock.for_index(@output)

      acquired, seconds = elapsed { contender.acquire }
      expect(acquired).to be(false)
      expect(seconds).to be < Woods::Coordination::PipelineLock::DEFAULT_GUARD_WAIT + 0.5

      acquired, seconds = elapsed { Woods::MCP::Server.send(:acquire_lock_briefly, contender) }
      expect(acquired).to be(false)
      expect(seconds).to be < Woods::MCP::Server::PIPELINE_LOCK_WAIT + 0.5

      acquired, seconds = elapsed { Object.new.extend(Woods::RakeHelpers).send(:woods_acquire_within, contender, 1.0) }
      expect(acquired).to be(false)
      expect(seconds).to be < 1.5

      Process.kill('CONT', a)
      expect(finish(a)).to eq(0)
      expect(contender.acquire).to be(true)
      contender.release
    end
  end
end
