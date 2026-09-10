# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'pathname'
require 'json'
require 'woods/atomic_file'

RSpec.describe Woods::AtomicFile do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe '.write' do
    it 'writes content to the path' do
      path = File.join(@dir, 'note.md')
      described_class.write(path, 'hello')
      expect(File.read(path)).to eq('hello')
    end

    it 'creates missing parent directories' do
      path = File.join(@dir, 'a', 'b', 'c.md')
      described_class.write(path, 'x')
      expect(File.read(path)).to eq('x')
    end

    it 'overwrites an existing file' do
      path = File.join(@dir, 'note.md')
      File.write(path, 'old')
      described_class.write(path, 'new')
      expect(File.read(path)).to eq('new')
    end

    it 'accepts a Pathname' do
      path = Pathname(File.join(@dir, 'p.md'))
      described_class.write(path, 'y')
      expect(File.read(path)).to eq('y')
    end

    it 'leaves no temp files behind on success' do
      described_class.write(File.join(@dir, 'note.md'), 'data')
      leftovers = Dir.children(@dir).reject { |f| f == 'note.md' }
      expect(leftovers).to be_empty
    end

    it 'writes 0600 by default — restrictive unless an artifact says otherwise' do
      path = File.join(@dir, 'note.md')
      described_class.write(path, 'data')
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    # O1: permissions are explicit per artifact. Only artifacts with a
    # documented cross-boundary consumer pass a wider mode; Tempfile's 0600
    # default must not silently widen (or silently forbid widening) anywhere.
    it 'applies an explicitly requested wider mode' do
      path = File.join(@dir, 'shared.md')
      described_class.write(path, 'data', mode: 0o644)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end

    it 'fsyncs the containing directory after the atomic rename' do
      expect(described_class).to receive(:fsync_directory).with(@dir).and_call_original

      described_class.write(File.join(@dir, 'note.md'), 'data')
    end

    # The durability model this gem publishes under: readers resolve only
    # through `generation.json`, so a payload file has no reader until the
    # pointer names it. `durable: false` drops the two forced flushes and
    # keeps everything that makes the write atomic (tempfile, chmod, rename).
    describe 'durable:' do
      it 'writes the same bytes and the same mode as the durable path' do
        durable = File.join(@dir, 'durable.json')
        deferred = File.join(@dir, 'deferred.json')
        content = JSON.generate('identifier' => 'User', 'note' => 'em dash \u2014 here')

        described_class.write(durable, content)
        described_class.write(deferred, content, durable: false)

        expect(File.binread(deferred)).to eq(File.binread(durable))
        expect(File.stat(deferred).mode & 0o777).to eq(File.stat(durable).mode & 0o777)
      end

      it 'honours an explicit mode while non-durable' do
        path = File.join(@dir, 'wide.json')
        described_class.write(path, 'data', mode: 0o644, durable: false)
        expect(File.stat(path).mode & 0o777).to eq(0o644)
      end

      it 'does not fsync the temp file or the directory' do
        fsyncs = 0
        allow_any_instance_of(Tempfile).to receive(:fsync) { fsyncs += 1 }
        expect(described_class).not_to receive(:fsync_directory)

        described_class.write(File.join(@dir, 'deferred.json'), 'data', durable: false)

        expect(fsyncs).to eq(0)
      end

      it 'still fsyncs both when durable (the default)' do
        fsyncs = 0
        allow_any_instance_of(Tempfile).to receive(:fsync) { fsyncs += 1 }
        expect(described_class).to receive(:fsync_directory).with(@dir).and_call_original

        described_class.write(File.join(@dir, 'durable.json'), 'data')

        expect(fsyncs).to eq(1)
      end

      it 'cleans up and preserves the target when a non-durable rename fails' do
        path = File.join(@dir, 'note.md')
        File.write(path, 'original')
        allow(File).to receive(:rename).and_raise(Errno::EACCES)

        expect { described_class.write(path, 'new', durable: false) }.to raise_error(Errno::EACCES)
        expect(File.read(path)).to eq('original')
        expect(Dir.children(@dir).reject { |f| f == 'note.md' }).to be_empty
      end
    end

    it 'uses unique temporary names for concurrent writers' do
      path = File.join(@dir, 'note.md')
      temporary_paths = Queue.new
      allow(Tempfile).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |tempfile| temporary_paths << tempfile.path }
      end

      contents = ['a' * 10_000, 'b' * 20_000]
      threads = contents.map { |content| Thread.new { described_class.write(path, content) } }
      threads.each(&:join)

      paths = 2.times.map { temporary_paths.pop }
      expect(paths.uniq.length).to eq(2)
      expect(contents).to include(File.read(path))
      expect(Dir.children(@dir)).to eq(['note.md'])
    end

    it 'cleans up and preserves the target when temp-file fsync fails' do
      path = File.join(@dir, 'note.md')
      File.write(path, 'original')
      allow_any_instance_of(Tempfile).to receive(:fsync).and_raise(IOError, 'disk failure')

      expect { described_class.write(path, 'new') }.to raise_error(IOError, 'disk failure')
      expect(File.read(path)).to eq('original')
      expect(Dir.children(@dir)).to eq(['note.md'])
    end

    it 'cleans up the temp file and re-raises if the rename fails, leaving the original intact' do
      path = File.join(@dir, 'note.md')
      File.write(path, 'original')
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { described_class.write(path, 'new') }.to raise_error(Errno::EACCES)
      expect(File.read(path)).to eq('original')
      leftovers = Dir.children(@dir).reject { |f| f == 'note.md' }
      expect(leftovers).to be_empty
    end
  end

  # One filesystem flush for a whole payload, replacing thousands of per-file
  # ones. The chain must never silently do nothing: if every faster strategy
  # is unavailable, the per-file fsync pass still runs.
  describe '.sync_directory_tree' do
    def build_tree
      FileUtils.mkdir_p(File.join(@dir, 'models'))
      FileUtils.mkdir_p(File.join(@dir, 'flows', 'nested'))
      File.write(File.join(@dir, 'manifest.json'), '{}')
      File.write(File.join(@dir, 'models', 'User.json'), '{}')
      File.write(File.join(@dir, 'flows', 'nested', 'show.json'), '{}')
    end

    it 'returns :syncfs and stops there when syncfs succeeds' do
      allow(described_class).to receive(:syncfs).and_return(:syncfs)
      expect(described_class).not_to receive(:sync_f)
      expect(described_class).not_to receive(:plain_sync)

      expect(described_class.sync_directory_tree(@dir)).to eq(:syncfs)
    end

    it 'falls back to sync -f when syncfs is unavailable' do
      allow(described_class).to receive(:syncfs).and_return(nil)
      allow(described_class).to receive(:sync_f).and_return(:sync_f)
      expect(described_class).not_to receive(:plain_sync)

      expect(described_class.sync_directory_tree(@dir)).to eq(:sync_f)
    end

    it 'falls back to a plain sync when sync -f fails' do
      allow(described_class).to receive(:syncfs).and_return(nil)
      allow(described_class).to receive(:sync_f).and_return(nil)
      allow(described_class).to receive(:plain_sync).and_return(:sync)

      expect(described_class.sync_directory_tree(@dir)).to eq(:sync)
    end

    it 'runs a per-file fsync pass over every file when nothing faster works' do
      build_tree
      allow(described_class).to receive(:syncfs).and_return(nil)
      allow(described_class).to receive(:sync_f).and_return(nil)
      allow(described_class).to receive(:plain_sync).and_return(nil)
      synced = []
      allow(described_class).to receive(:fsync_path) { |path| synced << path }

      expect(described_class.sync_directory_tree(@dir)).to eq(:fsync_pass)
      expect(synced).to include(
        File.join(@dir, 'manifest.json'),
        File.join(@dir, 'models', 'User.json'),
        File.join(@dir, 'flows', 'nested', 'show.json'),
        File.join(@dir, 'models'),
        File.join(@dir, 'flows', 'nested'),
        @dir,
        # The directory entry naming the tree lives in the parent.
        File.dirname(@dir)
      )
    end

    it 'reports the strategy it ran at debug level' do
      logger = instance_double(Logger, debug: nil)
      stub_const('Rails', double('Rails', logger: logger))
      allow(described_class).to receive(:syncfs).and_return(:syncfs)

      described_class.sync_directory_tree(@dir)

      expect(logger).to have_received(:debug) do |&block|
        expect(block.call).to include('syncfs')
      end
    end

    it 'is a no-op returning nil for a directory that does not exist' do
      expect(described_class).not_to receive(:syncfs)
      expect(described_class.sync_directory_tree(File.join(@dir, 'gone'))).to be_nil
    end

    it 'accepts a Pathname and really flushes a real directory' do
      build_tree
      expect(%i[syncfs sync_f sync fsync_pass])
        .to include(described_class.sync_directory_tree(Pathname(@dir)))
    end
  end

  # The reason .read exists at all.
  #
  # .write goes through binmode, so bytes land verbatim — but a plain
  # File.read tags the result with the process's *default external encoding*,
  # and a container with no locale set (LANG=C, the default in a plain Docker
  # image, which is exactly where the watch daemon is documented to run) makes
  # that US-ASCII. Any byte above 0x7F then raises on the first JSON.parse.
  #
  # Not hypothetical: the daemon writes status reasons containing em dashes, so
  # one ordinary lock contention under LANG=C broke `woods:watch_status`, the
  # hook sync's daemon-deference check and the `woods_status` tool — and
  # Status#read rescued JSON::ParserError and SystemCallError, neither of which
  # an Encoding::InvalidByteSequenceError is, so it raised straight out.
  describe '.read' do
    it 'round-trips non-ASCII content whatever the default external encoding is' do
      path = File.join(@dir, 'status.json')
      content = JSON.generate('reason' => 'lock held — retrying on the next event')
      described_class.write(path, content)

      original = Encoding.default_external
      begin
        # -W0: Ruby warns when the default external encoding is reassigned.
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII

        expect { JSON.parse(File.read(path)) }.to raise_error(EncodingError)
        expect(JSON.parse(described_class.read(path))['reason']).to include('—')
      ensure
        Encoding.default_external = original
        $VERBOSE = false
      end
    end
  end
end
