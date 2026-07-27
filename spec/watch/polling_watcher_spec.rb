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

  # The granularity the `age` helper above deliberately sidesteps, characterized
  # directly. Truncating mtime to whole seconds loses a second write inside the
  # same second permanently — there is no later event to catch it — and
  # save-then-formatter at a 1s poll interval is entirely ordinary.
  describe 'sub-second resolution' do
    it 'notices a second write within the same second' do
      write('app/models/user.rb', 'first')
      watcher.poll

      write('app/models/user.rb', 'first') # same length, same second
      File.utime(*Array.new(2) { Time.at(File.mtime(File.join(root, 'app/models/user.rb')).to_i + 0.4) },
                 File.join(root, 'app/models/user.rb'))

      expect(watcher.poll).to eq([File.join(root, 'app/models/user.rb')])
    end

    # The fallback for filesystems that genuinely only offer whole seconds:
    # a same-second rewrite that changes length is still caught.
    it 'notices a same-second rewrite of a different length' do
      path = write('app/models/user.rb', 'short')
      watcher.poll

      File.write(path, 'considerably longer contents')
      stamp = Time.at(File.mtime(path).to_i)
      File.utime(stamp, stamp, path)

      expect(watcher.poll).to eq([path])
    end
  end

  # A root a Dir.glob pattern cannot express when interpolated. Generated
  # worktree directories really do contain brackets.
  describe 'awkward roots' do
    it 'watches a root containing glob metacharacters' do
      nested = File.join(root, 'slot[1]{a}')
      FileUtils.mkdir_p(File.join(nested, 'app/models'))
      watcher = described_class.new(root: nested, interval: 0)
      watcher.poll

      target = File.join(nested, 'app/models/user.rb')
      File.write(target, 'x')

      expect(watcher.poll).to eq([target])
    end
  end

  describe '#stop' do
    # The daemon's signal handler and its watcher thread race by construction.
    it 'is honoured when it arrives before start' do
      write('app/models/user.rb')
      watcher.stop
      yielded = false

      watcher.start { yielded = true }

      expect(yielded).to be(false)
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
