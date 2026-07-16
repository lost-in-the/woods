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
  # Subprocess output arrives in the locale's default external encoding.
  # Under a POSIX/C locale (common in containers and CI) that's US-ASCII,
  # and the server's boot log contains UTF-8 punctuation — matching a
  # Regexp against it would raise ArgumentError. Normalize before matching.
  def utf8(output)
    output.force_encoding(Encoding::UTF_8).scrub
  end

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
      expect(utf8(err)).to match(/No index directory specified/i)
      expect(utf8(err)).to match(/Usage:/)
    end

    # Awaiting-index boot: a named-but-empty (or missing) index dir no longer
    # hard-fails by default — WOODS_REQUIRE_INDEX=1 restores the strict exit.
    it 'exits non-zero for a missing index directory under WOODS_REQUIRE_INDEX=1' do
      env = { 'WOODS_REQUIRE_INDEX' => '1' }
      _out, err, status = Open3.capture3(env, wrapper, '/definitely/not/a/real/woods/dir')

      expect(status.exitstatus).to eq(1)
      expect(utf8(err)).to match(/does not exist/i)
      expect(utf8(err)).to match(/bundle exec rake woods:extract/)
    end

    it 'exits non-zero for a directory missing manifest.json under WOODS_REQUIRE_INDEX=1' do
      Dir.mktmpdir do |empty_dir|
        env = { 'WOODS_REQUIRE_INDEX' => '1' }
        _out, err, status = Open3.capture3(env, wrapper, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(utf8(err)).to match(/No manifest\.json/)
        expect(utf8(err)).to match(/bundle exec rake woods:extract/)
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

      stderr_output = utf8(stderr.read)
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

    # #138: extract-only host (manifest.json present, no woods.json, no provider)
    # must boot into pattern/structural mode by default — NOT fail-fast with
    # MissingArtifact — and with no WOODS_REQUIRE_INDEX / WOODS_ALLOW_AUTODETECT
    # set. We confirm the process is still alive after boot (it entered the stdio
    # transport) rather than having exited 2.
    it 'boots in pattern-only mode for an extract-only dir with no woods.json' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'manifest.json'))
        env = {
          'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
          'WOODS_REQUIRE_INDEX' => nil,
          'WOODS_ALLOW_AUTODETECT' => nil,
          'OPENAI_API_KEY' => nil,
          # Dead port so autodetect can't wire a real Ollama provider.
          'OLLAMA_BASE_URL' => 'http://127.0.0.1:19999'
        }
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, 'bundle', 'exec', 'ruby', ruby_bin, dir)
        sleep 2
        # Still alive == booted into the server (did not exit 2 on MissingArtifact).
        booted = wait_thr.alive?
        Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
        wait_thr.join(5)
        err = utf8(stderr.read)
        stdin.close
        stdout.close
        stderr.close

        expect(booted).to be(true)
        expect(err).not_to include('MissingArtifact')
      end
    end

    it 'exits non-zero for a missing index directory under WOODS_REQUIRE_INDEX=1' do
      env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'), 'WOODS_REQUIRE_INDEX' => '1' }
      _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, '/no/such/path')

      expect(status.exitstatus).to eq(1)
      expect(utf8(err)).to match(/Index directory does not exist/i)
    end

    it 'exits non-zero for a directory missing manifest.json under WOODS_REQUIRE_INDEX=1' do
      Dir.mktmpdir do |empty_dir|
        env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'), 'WOODS_REQUIRE_INDEX' => '1' }
        _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(utf8(err)).to match(/No manifest\.json/)
      end
    end

    # Awaiting-index boot (default): an explicitly named directory with no
    # manifest boots into the stdio transport and stays alive, announcing
    # awaiting-index mode on stderr — so editor/agent configs can register
    # woods-mcp before the first extraction has ever run.
    it 'boots in awaiting-index mode for a named directory with no manifest.json' do
      Dir.mktmpdir do |empty_dir|
        env = {
          'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
          'WOODS_REQUIRE_INDEX' => nil,
          'OPENAI_API_KEY' => nil,
          'OLLAMA_BASE_URL' => 'http://127.0.0.1:19999'
        }
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, 'bundle', 'exec', 'ruby', ruby_bin, empty_dir)
        sleep 2
        booted = wait_thr.alive?
        Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
        wait_thr.join(5)
        err = utf8(stderr.read)
        stdin.close
        stdout.close
        stderr.close

        expect(booted).to be(true)
        expect(err).to match(/awaiting-index/i)
      end
    end

    # ── BootstrapError rescue — typed exception surface ────────────
    # When build_retriever raises a typed BootstrapError, the
    # top-level rescue in exe/woods-mcp must print the class name
    # (grep-friendly for operators), the message, and exit with a
    # distinct nonzero code (2) so ops tooling can distinguish "bad
    # config" from "missing directory" (exit 1).
    describe 'BootstrapError handling' do
      it 'exits 2 with MissingArtifact class name when woods.json is absent under WOODS_REQUIRE_INDEX=1' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'manifest.json')) # pass the dir-exists check
          env = {
            'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
            # Extract-only would boot in pattern-only mode by default (#138);
            # the strict flag opts back into fail-closed behaviour.
            'WOODS_REQUIRE_INDEX' => '1',
            'OPENAI_API_KEY' => nil,
            # Point Ollama at a dead port so the autodetect path — if it
            # somehow fires — won't accidentally find a running local
            # Ollama and obscure the test.
            'OLLAMA_BASE_URL' => 'http://127.0.0.1:19999'
          }

          # The fixture has a manifest, so resolve_index_dir passes;
          # build_retriever runs and hits MissingArtifact because there's
          # no woods.json and strict mode is requested.
          _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, dir)

          expect(status.exitstatus).to eq(2)
          expect(utf8(err)).to match(/MissingArtifact/)
          expect(utf8(err)).to match(/WOODS_REQUIRE_INDEX/)
        end
      end
    end
  end
end
