# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
require 'woods/published_index'
require 'woods/coordination/pipeline_lock'
require_relative '../support/source_input_app'

# The #1004 race through the real entry points, in fresh Rails processes:
# `woods-extract full`, `incremental` and `refresh`. Writer A stops itself
# (SIGSTOP, heartbeat included) at a named publish point; its lease is
# expired; writer B, a full extraction of an edited tree, takes the lock over
# and publishes; A is resumed. The default suite runs the same race at the
# publish layer (spec/integration/writer_fencing_spec.rb).
RSpec.describe 'Writer fencing through the extraction entry points (#1004)', :aggregate_failures, :booted_app,
               if: RUBY_PLATFORM.include?('linux') do
  include SourceInputApp

  let(:root) { File.expand_path('../..', __dir__) }
  let(:probe) { 'app/services/fence_probe.rb' }

  def command(app, *args)
    [RbConfig.ruby, '-I', File.join(root, 'lib'), File.join(root, 'exe/woods-extract'), '--root', app, *args]
  end

  # The fixture Rakefile installs the test seam; production code reads no
  # environment for it.
  def make_fencing_app(app)
    make_source_app(app)
    rakefile = File.join(app, 'Rakefile')
    File.write(rakefile, <<~RUBY + File.read(rakefile))
      require 'woods/publication_seam'
      if (pause_at = ENV['WOODS_FENCE_PAUSE_AT'])
        Woods::PublicationSeam.hook = lambda do |point, _dir|
          next unless point.to_s == pause_at

          File.write(ENV.fetch('WOODS_FENCE_READY'), Process.pid.to_s)
          Process.kill('STOP', Process.pid)
        end
      end
    RUBY
    write_probe(app, :a)
  end

  # A failed example must not leave a stopped writer behind.
  after do
    Array(@spawned).each do |pid|
      Process.kill('CONT', pid)
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil
    end
  end

  def write_probe(app, value)
    File.write(File.join(app, probe), "class FenceProbe; def call; #{value.inspect}; end; end\n")
  end

  def output(app)
    File.join(app, 'tmp/woods')
  end

  def launch(app, *args)
    out, err, result = Open3.capture3(*command(app, *args))
    expect(result).to be_success, "#{out}\n#{err}"
  end

  def marker(app)
    Woods::Generation.new(output_dir: output(app)).current
  end

  def tree_hashes(app, number)
    dir = Woods::PayloadStore.new(output(app)).path_for(number)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: dir.to_s).sort.filter_map do |relative|
      path = dir.join(relative)
      [relative, Digest::SHA256.file(path.to_s).hexdigest] if path.file?
    end.to_h
  end

  def generation_dirs(app)
    Dir.children(File.join(output(app), 'payloads')).grep(/\Agen-\d+\z/).sort
  end

  def probe_source(index)
    index.unit('FenceProbe')&.fetch('source_code', nil)
  end

  def wait_until(what, timeout: 120)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def expire_lease!(app)
    old = Time.now - Woods::Coordination::PipelineLock::INDEX_WRITER_STALE_TIMEOUT - 60
    File.utime(old, old, File.join(output(app), 'extraction.lock'))
  end

  # @return [Array(Thread, Integer)] the waiter for A's launcher and the pid
  #   of the stopped rake process
  def start_paused_writer(app, args, pause_at)
    ready = File.join(app, 'fence-ready')
    env = { 'WOODS_FENCE_PAUSE_AT' => pause_at.to_s, 'WOODS_FENCE_READY' => ready }
    stdin, stdout_err, waiter = Open3.popen2e(env, *command(app, *args))
    stdin.close
    (@spawned ||= []) << waiter.pid
    reader = Thread.new { stdout_err.read }
    wait_until('writer A to pause') { File.exist?(ready) && !File.empty?(ready) }
    pid = Integer(File.read(ready))
    @spawned << pid
    wait_until('writer A to stop') { File.read("/proc/#{pid}/stat")[/\) (\S)/, 1] == 'T' }
    [waiter, reader, pid]
  end

  {
    'full' => ->(_app) { ['full'] },
    'incremental' => ->(_app) { %w[incremental app/services/fence_probe.rb] },
    'refresh' => ->(_app) { %w[refresh services] }
  }.each do |entry, args_for|
    it "keeps B's publication intact when a #{entry} writer resumes after the takeover" do
      Dir.mktmpdir('woods-fencing-booted') do |app|
        make_fencing_app(app)
        launch(app, 'full')
        # Give incremental and refresh something to publish.
        write_probe(app, :a_changed) unless entry == 'full'
        pinned = Woods::PublishedIndex.new(output(app), generation: 1)
        pinned_source = probe_source(pinned)

        waiter, reader, a_pid = start_paused_writer(app, args_for.call(app), :before_promotion)
        expire_lease!(app)
        write_probe(app, :b)
        launch(app, 'full')

        published = marker(app)
        b_hashes = tree_hashes(app, published.number)
        dirs = generation_dirs(app)
        current = Woods::PublishedIndex.new(output(app))
        expect(probe_source(current)).to include(':b')

        Process.kill('CONT', a_pid)
        a_status = waiter.value
        a_output = reader.value

        expect(a_status).not_to be_success
        expect(a_output).to include('no longer held by this writer')
        expect(marker(app).to_h).to eq(published.to_h)
        expect(tree_hashes(app, published.number)).to eq(b_hashes)
        expect(generation_dirs(app)).to eq(dirs)
        expect(probe_source(current)).to include(':b')
        expect(probe_source(pinned)).to eq(pinned_source)
        Woods::PublishedIndex.open(output(app)) { |fresh| expect(probe_source(fresh)).to include(':b') }
        expect(Dir.children(File.join(output(app), 'payloads')).grep(/\A\.stage-/)).to be_empty
      ensure
        pinned&.close
        current&.close
      end
    end
  end

  it 'holds a takeover off while a full writer is inside the fence, then publishes both' do
    Dir.mktmpdir('woods-fencing-booted') do |app|
      make_fencing_app(app)
      launch(app, 'full')

      waiter, reader, a_pid = start_paused_writer(app, ['full'], :promoted)
      expire_lease!(app)
      guard = File.join(output(app), Woods::Coordination::PipelineLock.guard_filename('extraction'))
      expect(File.open(guard, File::RDWR) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }).to be(false)
      write_probe(app, :b)
      b_stdin, b_out, b_waiter = Open3.popen2e(*command(app, 'full'))
      b_stdin.close
      @spawned << b_waiter.pid
      b_reader = Thread.new { b_out.read }

      Process.kill('CONT', a_pid)
      expect(waiter.value).to be_success, reader.value
      expect(b_waiter.value).to be_success, b_reader.value

      expect(marker(app).number).to eq(3)
      Woods::PublishedIndex.open(output(app), generation: 2) { |index| expect(probe_source(index)).to include(':a') }
      Woods::PublishedIndex.open(output(app)) { |index| expect(probe_source(index)).to include(':b') }
    end
  end
end
