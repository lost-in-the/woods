# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Integration specs for the MCP CLI entry points. These shell out to the
# real executables rather than invoking Ruby classes directly — the point
# is to verify the boundary between the shell wrapper, the Ruby process,
# and the filesystem.
#
# The wrapper (exe/woods-mcp-start) is a bash script, so these specs are
# the only coverage for its validation logic. The Ruby binary (exe/woods-mcp)
# is exercised here as a boot-smoke test: we spawn it against a fixture,
# let it block on stdin, then verify it produced no boot-time errors on stderr.
RSpec.describe 'MCP CLI integration' do
  let(:gem_root) { File.expand_path('../..', __dir__) }
  let(:wrapper) { File.join(gem_root, 'exe/woods-mcp-start') }
  let(:ruby_bin) { File.join(gem_root, 'exe/woods-mcp') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }

  # ── exe/woods-mcp-start (bash wrapper) ───────────────────────────

  describe 'woods-mcp-start wrapper' do
    it 'exits non-zero with a usage message when no index directory is given' do
      # Make sure no env override is present during this run.
      _out, err, status = Open3.capture3({ 'WOODS_DIR' => nil }, wrapper)

      expect(status.exitstatus).to eq(1)
      expect(err).to match(/No index directory specified/i)
      expect(err).to match(/Usage:/)
    end

    it 'exits non-zero with a clear message when the index directory does not exist' do
      _out, err, status = Open3.capture3(wrapper, '/definitely/not/a/real/woods/dir')

      expect(status.exitstatus).to eq(1)
      expect(err).to match(/does not exist/i)
      expect(err).to match(/bundle exec rake woods:extract/)
    end

    it 'exits non-zero when the directory is missing manifest.json' do
      Dir.mktmpdir do |empty_dir|
        _out, err, status = Open3.capture3(wrapper, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to match(/No manifest\.json/)
        expect(err).to match(/bundle exec rake woods:extract/)
      end
    end
  end

  # ── exe/woods-mcp (Ruby entry point) ─────────────────────────────

  describe 'woods-mcp Ruby binary' do
    # Booting the binary means requiring the whole gem + Server.build. If
    # anything raises during require/boot, stderr will contain a backtrace.
    # We give the subprocess a short window, kill it, then inspect stderr.
    def boot_with_fixture(env = {})
      env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile') }.merge(env)
      stdin, stdout, stderr, wait_thr = Open3.popen3(env, 'bundle', 'exec', 'ruby', ruby_bin, fixture_dir)

      # Let the process get past boot. 2s is generous for a fixture index.
      sleep 2
      Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
      wait_thr.join(5)

      stderr_output = stderr.read
      stdin.close
      stdout.close
      stderr.close
      stderr_output
    end

    it 'boots against the fixture without raising a Ruby error' do
      stderr_output = boot_with_fixture

      # No Ruby error signatures on stderr.
      expect(stderr_output).not_to include("can't load such file")
      expect(stderr_output).not_to include('NoMethodError')
      expect(stderr_output).not_to include('uncaught throw')
      expect(stderr_output).not_to match(/from .+\.rb:\d+:in/) # backtrace frame
    end

    it 'exits non-zero when pointed at a missing index directory' do
      env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile') }
      _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, '/no/such/path')

      expect(status.exitstatus).to eq(1)
      expect(err).to match(/Index directory does not exist/i)
    end

    it 'exits non-zero when the directory is missing manifest.json' do
      Dir.mktmpdir do |empty_dir|
        env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile') }
        _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(err).to match(/No manifest\.json/)
      end
    end
  end
end
