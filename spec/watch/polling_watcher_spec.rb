# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/watch/watcher'

RSpec.describe Woods::Watch::PollingWatcher do
  let(:root) { Dir.mktmpdir('woods_poll') }

  after { FileUtils.rm_rf(root) }

  subject(:watcher) { described_class.new(root: root, interval: 0) }

  def write(relative, contents = 'x')
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  # mtime has one-second resolution on many filesystems, so a same-second
  # rewrite is invisible to a stat-based watcher. Setting it explicitly keeps
  # these examples about the diffing logic rather than about clock granularity.
  def age(relative, seconds)
    path = File.join(root, relative)
    time = Time.now - seconds
    File.utime(time, time, path)
  end

  describe '#poll' do
    it 'reports nothing on the first scan, so a boot is not a storm' do
      write('app/models/user.rb')

      expect(watcher.poll).to be_empty
    end

    it 'reports a created file' do
      watcher.poll
      write('app/models/user.rb')

      expect(watcher.poll).to eq([File.join(root, 'app/models/user.rb')])
    end

    it 'reports a modified file' do
      write('app/models/user.rb')
      age('app/models/user.rb', 10)
      watcher.poll

      write('app/models/user.rb', 'changed')

      expect(watcher.poll).to eq([File.join(root, 'app/models/user.rb')])
    end

    it 'reports a deleted file' do
      write('app/models/user.rb')
      watcher.poll

      FileUtils.rm_f(File.join(root, 'app/models/user.rb'))

      expect(watcher.poll).to eq([File.join(root, 'app/models/user.rb')])
    end

    it 'reports a rename as both sides, matching --no-renames diff semantics' do
      write('app/models/old.rb')
      watcher.poll

      FileUtils.mv(File.join(root, 'app/models/old.rb'), File.join(root, 'app/models/new.rb'))

      expect(watcher.poll).to contain_exactly(
        File.join(root, 'app/models/old.rb'),
        File.join(root, 'app/models/new.rb')
      )
    end

    it 'reports nothing when nothing moved' do
      write('app/models/user.rb')
      watcher.poll

      expect(watcher.poll).to be_empty
    end
  end

  describe 'ignored directories' do
    it 'skips the noise that would dominate a scan' do
      watcher.poll

      write('.git/objects/ab/cdef')
      write('node_modules/left-pad/index.js')
      write('tmp/cache/thing')
      write('log/development.log')

      expect(watcher.poll).to be_empty
    end

    it 'still reports real source under a similarly-named path' do
      watcher.poll
      write('app/models/tmp_report.rb')

      expect(watcher.poll).to eq([File.join(root, 'app/models/tmp_report.rb')])
    end

    it 'honours a custom ignore list' do
      custom = described_class.new(root: root, interval: 0, ignored: %w[app/assets])
      custom.poll
      write('app/assets/builds/app.css')
      write('app/models/user.rb')

      expect(custom.poll).to eq([File.join(root, 'app/models/user.rb')])
    end
  end

  describe '#start' do
    it 'yields batches until stopped' do
      write('app/models/user.rb')
      batches = []

      # The sleeper is where the watcher would block; drive it instead of
      # waiting on real time.
      stepper = described_class.new(root: root, interval: 0, sleeper: lambda { |_|
        write('app/models/added.rb')
      })

      stepper.start do |changed|
        batches << changed
        stepper.stop
      end

      expect(batches.flatten).to include(File.join(root, 'app/models/added.rb'))
    end
  end
end
