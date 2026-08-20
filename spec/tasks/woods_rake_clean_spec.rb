# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'time'

# woods:clean used to be a bare rm_rf (#170): run mid-daemon-cycle it deleted
# the extraction lock itself, evaporating the "writers serialize on
# PipelineLock" invariant at the worst possible moment. The helper it now
# routes through refuses under a live daemon, then deletes under the lock,
# sparing the lock file so release removes it last. The embed tasks were the
# other unlocked writers — they share the same lock domain now.
RSpec.describe 'woods:clean and embed locking (#170)' do
  let(:source) { File.read(File.expand_path('../../lib/tasks/woods.rake', __dir__), encoding: 'UTF-8') }

  # From the `task <name>` line to the next task/desc at the same indent —
  # same derivation as woods_rake_requires_spec.
  def task_body(name)
    lines = source.lines
    start = lines.index { |line| line.match?(/^  task[ :]+#{Regexp.escape(name)}\b/) }
    raise "could not locate the #{name} task in lib/tasks/woods.rake" if start.nil?

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.match?(/^  (desc|task)\b/) } || rest.length
    rest[0...stop].join
  end

  # Text-level guards, same style as woods_rake_requires_spec: the task bodies
  # cannot be invoked without a booted Rails, but "this writer serializes on
  # the extraction lock" is visible in the source and regresses visibly here.
  describe 'writer serialization' do
    it 'woods:clean routes deletion through the guarded helper, not a bare rm_rf' do
      body = task_body('clean')

      expect(body).to include('woods_clean_index')
      expect(body).not_to include('FileUtils.rm_rf')
    end

    %w[embed embed_incremental].each do |name|
      it "woods:#{name} takes the extraction lock" do
        expect(task_body(name)).to include('woods_with_extraction_lock')
      end
    end

    it 'woods:extract_framework is a locked alias for refresh(:rails_source)' do
      body = task_body('extract_framework')

      expect(body).to include('woods_with_extraction_lock')
      expect(body).to include('refresh(:rails_source)')
      # The old hand-rolled writer bypassed AtomicFile, _index.json, the
      # manifest, the lock and the generation (#169) — it must stay gone.
      # Comments are stripped: the body may (and does) *mention* File.write.
      code_lines = body.lines.reject { |line| line.strip.start_with?('#') }
      expect(code_lines.grep(/File\.write/)).to be_empty
    end
  end

  describe 'woods_clean_index executed against a real directory' do
    before { load File.expand_path('../../lib/tasks/woods.rake', __dir__) }

    def populate(dir)
      FileUtils.mkdir_p(File.join(dir, 'models'))
      File.write(File.join(dir, 'models', 'User_abc.json'), '{}')
      File.write(File.join(dir, 'manifest.json'), '{}')
    end

    # A status record Status#alive? believes: live state, this process's pid,
    # this host, fresh timestamp.
    def live_daemon_status!(dir)
      require 'woods/watch/status'
      File.write(
        File.join(dir, Woods::Watch::Status::FILENAME),
        JSON.generate(
          'state' => 'running',
          'pid' => Process.pid,
          'host' => Woods::Watch::Status.host_identity,
          'updated_at' => Time.now.utc.iso8601
        )
      )
    end

    it 'deletes the index under the lock and removes the emptied directory' do
      Dir.mktmpdir('woods_clean') do |parent|
        dir = File.join(parent, 'woods')
        FileUtils.mkdir_p(dir)
        populate(dir)

        expect(Object.new.send(:woods_clean_index, dir, wait: 0)).to eq(:cleaned)
        expect(Dir.exist?(dir)).to be(false)
        expect(File.file?("#{dir}.extraction.lock.guard")).to be(true)
      end
    end

    it 'refuses while a live daemon is maintaining the index' do
      Dir.mktmpdir('woods_clean') do |dir|
        populate(dir)
        live_daemon_status!(dir)

        result = nil
        expect { result = Object.new.send(:woods_clean_index, dir, wait: 0) }
          .to output(/refusing to delete/).to_stderr
        expect(result).to eq(:refused)
        expect(File.exist?(File.join(dir, 'manifest.json'))).to be(true)
      end
    end

    it 'honours WOODS_IGNORE_WATCH=1 over a live daemon, same as woods:incremental' do
      Dir.mktmpdir('woods_clean') do |parent|
        dir = File.join(parent, 'woods')
        FileUtils.mkdir_p(dir)
        populate(dir)
        live_daemon_status!(dir)

        original = ENV.fetch('WOODS_IGNORE_WATCH', nil)
        ENV['WOODS_IGNORE_WATCH'] = '1'
        begin
          expect(Object.new.send(:woods_clean_index, dir, wait: 0)).to eq(:cleaned)
          expect(Dir.exist?(dir)).to be(false)
        ensure
          original.nil? ? ENV.delete('WOODS_IGNORE_WATCH') : ENV['WOODS_IGNORE_WATCH'] = original
        end
      end
    end

    it 'spares the lock file while everything else is deleted' do
      Dir.mktmpdir('woods_clean') do |parent|
        dir = File.join(parent, 'woods')
        FileUtils.mkdir_p(dir)
        populate(dir)

        # Observe the directory at the moment the deletion loop first fires:
        # the held lock must still be present while the other entries go.
        seen_during = nil
        allow(FileUtils).to receive(:rm_rf).and_wrap_original do |original, *args|
          seen_during ||= Dir.children(dir)
          original.call(*args)
        end

        Object.new.send(:woods_clean_index, dir, wait: 0)

        expect(seen_during).to include('extraction.lock')
      end
    end
  end
end
