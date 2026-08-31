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
# These specs cover the wrapper's validation and protocol environment behavior.
# The Ruby binary (exe/woods-mcp) is exercised here as a boot-smoke test: we
# spawn it against a fixture, then verify it produced no boot-time errors.
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

  # ── exe/woods-mcp-start wrapper ──────────────────────────────────

  describe 'woods-mcp-start wrapper' do
    it 'exits non-zero with a usage message when no index directory is given' do
      # Make sure no env override is present during this run.
      _out, err, status = Open3.capture3({ 'WOODS_DIR' => nil }, wrapper)

      expect(status.exitstatus).to eq(1)
      expect(utf8(err)).to match(/No index directory specified/i)
      expect(utf8(err)).to match(/Usage:/)
    end

    it 'exits non-zero with a clear message when the index directory does not exist' do
      _out, err, status = Open3.capture3(wrapper, '/definitely/not/a/real/woods/dir')

      expect(status.exitstatus).to eq(1)
      expect(utf8(err)).to match(/does not exist/i)
      expect(utf8(err)).to match(/bundle exec rake woods:extract/)
    end

    it 'exits non-zero when the directory is missing manifest.json' do
      Dir.mktmpdir do |empty_dir|
        _out, err, status = Open3.capture3(wrapper, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(utf8(err)).to match(/No manifest\.json/)
        expect(utf8(err)).to match(/bundle exec rake woods:extract/)
      end
    end

    # A payload-born index has no manifest.json at the root — it lives under
    # the directory generation.json's `payload` pointer names. The pre-flight
    # check must follow that pointer (mirroring Woods::Generation#payload_dir
    # / Bootstrapper.manifest_present?) rather than reject a perfectly valid,
    # freshly-extracted index.
    it 'passes preflight for a payload-born index with no manifest.json at the root' do
      Dir.mktmpdir do |dir|
        payload_dir = File.join(dir, 'payloads', 'gen-1')
        FileUtils.mkdir_p(payload_dir)
        FileUtils.touch(File.join(payload_dir, 'manifest.json'))
        File.write(File.join(dir, 'generation.json'),
                   JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))

        stdin, stdout, stderr, wait_thr = Open3.popen3(wrapper, dir)
        sleep 2
        Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
        wait_thr.join(5)
        error_output = utf8(stderr.read)
        stdin.close
        stdout.close
        stderr.close

        expect(error_output).not_to match(/No manifest\.json/)
      end
    end

    it 'still rejects a directory with neither a root manifest nor a resolvable payload manifest' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'generation.json'),
                   JSON.generate('number' => 1, 'token' => 'abc', 'payload' => 'payloads/gen-1'))

        _out, err, status = Open3.capture3(wrapper, dir)

        expect(status.exitstatus).to eq(1)
        expect(utf8(err)).to match(/No manifest\.json/)
      end
    end

    # The wrapper used to default MCP_PROTOCOL_VERSION to 2024-11-05. The mcp
    # gem's server is dual-era — it answers `initialize` for legacy clients and
    # serves per-request metadata for modern ones — and pinning is the single
    # action that collapses it to one era, so the unpinned server is the more
    # compatible one. A regression here is silent: everything still works, just
    # four protocol revisions behind.
    describe 'protocol version handling' do
      def boot_wrapper(env)
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, wrapper, fixture_dir)
        sleep 2
        Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
        wait_thr.join(5)
        error_output = utf8(stderr.read)
        stdin.close
        stdout.close
        stderr.close
        error_output
      end

      it 'leaves protocol negotiation unpinned by default' do
        expect(boot_wrapper('MCP_PROTOCOL_VERSION' => nil)).not_to include('Pinning MCP protocol version')
      end

      it 'passes through MCP_PROTOCOL_VERSION when the operator sets one' do
        output = boot_wrapper('MCP_PROTOCOL_VERSION' => '2025-11-25')

        expect(output).to include('Pinning MCP protocol version to 2025-11-25')
      end
    end
  end

  # ── exe/woods-mcp (Ruby entry point) ─────────────────────────────

  describe 'woods-mcp Ruby binary' do
    it 'pins only the protocol version on the built server configuration' do
      # encoding: pinned so the multibyte executable source scans under LANG=C
      source = File.read(ruby_bin, encoding: Encoding::UTF_8)

      expect(source).to include("server.configuration.protocol_version = ENV['MCP_PROTOCOL_VERSION']")
      expect(source).not_to match(/server\.configuration\s*=/)
    end

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

    it 'exits non-zero when pointed at a missing index directory' do
      env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile') }
      _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, '/no/such/path')

      expect(status.exitstatus).to eq(1)
      expect(utf8(err)).to match(/Index directory does not exist/i)
    end

    it 'exits non-zero when the directory is missing manifest.json' do
      Dir.mktmpdir do |empty_dir|
        env = { 'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile') }
        _out, err, status = Open3.capture3(env, 'bundle', 'exec', 'ruby', ruby_bin, empty_dir)

        expect(status.exitstatus).to eq(1)
        expect(utf8(err)).to match(/No manifest\.json/)
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

      # M9: an empty-but-set OPENAI_API_KEY is not a credential. Before the
      # blank-key guard, autodetect wired :openai with api_key: "" (skipping
      # the Ollama probe a missing key gets), Builder raised a raw
      # Woods::ConfigurationError, and the top-level rescue — keyed on
      # BootstrapError only — let it escape as a backtrace crash. The key
      # must behave as absent: pattern-only boot, no crash.
      it 'boots pattern-only when OPENAI_API_KEY is set to an empty string' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'manifest.json'))
          env = {
            'BUNDLE_GEMFILE' => File.join(gem_root, 'Gemfile'),
            'OPENAI_API_KEY' => '',
            'OLLAMA_BASE_URL' => 'http://127.0.0.1:19999'
          }
          stdin, stdout, stderr, wait_thr = Open3.popen3(env, 'bundle', 'exec', 'ruby', ruby_bin, dir)
          sleep 2
          booted = wait_thr.alive?
          Process.kill('TERM', wait_thr.pid) if wait_thr.alive?
          wait_thr.join(5)
          err = utf8(stderr.read)
          stdin.close
          stdout.close
          stderr.close

          expect(booted).to be(true)
          expect(err).not_to include('ConfigurationError')
          expect(err).not_to match(/from .+\.rb:\d+:in/) # backtrace frame
        end
      end
    end
  end
end
