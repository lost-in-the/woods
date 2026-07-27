# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/watch/watcher'

# The listen backend had an injectable seam and no specs. Woods does not depend
# on the `listen` gem, so these drive a stand-in that honours the same contract:
# `Listen.to(dir, ignore:) { |modified, added, removed| }` returning something
# that responds to `start`/`stop`.
RSpec.describe Woods::Watch::ListenWatcher do
  let(:root) { Dir.mktmpdir('woods_listen') }

  after { FileUtils.rm_rf(root) }

  # Captures the block Listen would call and lets an example fire it.
  def fake_listen
    Class.new do
      class << self
        attr_accessor :captured, :ignore, :started, :on_start

        def to(_dir, ignore:, &block)
          self.ignore = ignore
          self.captured = block
          self
        end

        def start
          self.started = true
          on_start&.call
        end

        def stop = nil
      end
    end
  end

  describe '#start' do
    it 'merges modified, added and removed into one batch' do
      listen = fake_listen
      watcher = described_class.new(root: root, listen_class: listen)
      batches = []

      listen.on_start = lambda do
        listen.captured.call(['a.rb'], ['b.rb'], ['c.rb'])
        watcher.stop
      end
      watcher.start { |changed| batches << changed }

      expect(batches).to eq([%w[a.rb b.rb c.rb]])
    end

    it 'does not yield an empty batch' do
      listen = fake_listen
      watcher = described_class.new(root: root, listen_class: listen)
      yielded = false

      listen.on_start = lambda do
        listen.captured.call([], [], [])
        watcher.stop
      end
      watcher.start { yielded = true }

      expect(yielded).to be(false)
    end

    it 'translates a backend that cannot start into a WatcherError' do
      listen = fake_listen
      listen.on_start = -> { raise Errno::ENOSPC, 'inotify watch limit reached' }
      watcher = described_class.new(root: root, listen_class: listen)

      expect { watcher.start { nil } }.to raise_error(Woods::Watch::WatcherError, /ENOSPC|No space/)
    end

    # Only the setup is wrapped in the WatcherError rescue now. The parking loop
    # sitting outside it is what makes "failed to start" mean what it says —
    # previously anything raised for the whole life of the daemon, including by
    # the extraction inside on_change, came back as a start failure and the
    # daemon retired a working backend.
    it 'parks after a successful start and unparks on stop from another thread' do
      listen = fake_listen
      watcher = described_class.new(root: root, listen_class: listen)
      listen.on_start = -> { Thread.new { watcher.stop } }

      # Returns normally rather than raising a WatcherError for the ordinary
      # case of running until someone stops it.
      expect { Timeout.timeout(10) { watcher.start { nil } } }.not_to raise_error
      expect(listen.started).to be(true)
    end

    it 'honours a stop that arrives before it parks' do
      listen = fake_listen
      watcher = described_class.new(root: root, listen_class: listen)
      listen.on_start = -> { watcher.stop }

      expect { Timeout.timeout(10) { watcher.start { nil } } }.not_to raise_error
    end

    it 'passes the ignore list through as anchored patterns' do
      listen = fake_listen
      watcher = described_class.new(root: root, ignored: %w[tmp], listen_class: listen)
      listen.on_start = -> { watcher.stop }

      watcher.start { nil }

      expect(listen.ignore.first).to match('tmp/cache')
      expect(listen.ignore.first).not_to match('app/tmp/cache')
    end
  end
end
