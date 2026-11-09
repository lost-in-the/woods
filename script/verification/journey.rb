# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'time'
require_relative 'command'
require 'tmpdir'

# A bounded adapter around an existing real Rails fixture, not a new extractor.
module WoodsVerification
  LIMITS = [
    'Only the nested job queue fact is compared, not the entire index.',
    'Fresh task processes are exercised; resident reload and native watch are untested.',
    'No installed gem, client app, live backend, hosted CI or merge-policy verification.'
  ].freeze

  module DiagnosticReceipt
    private

    def checkpoint!
      destination = File.join(@evidence, 'receipt.json')
      temporary = "#{destination}.tmp"
      File.write(temporary, JSON.pretty_generate(@receipt))
      File.rename(temporary, destination)
    end

    def finalize_receipt
      @receipt[:provenance] = ending_provenance
      invalidate_outcome unless @receipt[:provenance][:valid]
      @receipt[:finished_at] = Time.now.utc.iso8601
      checkpoint!
    end

    def ending_provenance
      @receipt[:ending_candidate] = identity
      return { valid: true } if @receipt[:candidate] && @receipt[:candidate] == @receipt[:ending_candidate]

      { valid: false, reason: @receipt[:candidate] ? 'identity_changed' : 'missing_start_identity' }
    rescue StandardError => e
      { valid: false, reason: 'identity_lookup_failed', error: "#{e.class}: #{e.message}" }
    end

    def invalidate_outcome
      @receipt[:diagnostic_outcome] = @receipt.slice(:status, :error)
      return if @receipt[:status] == 'interrupted'

      @receipt[:status] = 'blocked_environment'
      @receipt[:error] = "Candidate provenance is invalid: #{@receipt[:provenance][:reason]}; " \
                         'the diagnostic outcome cannot be attributed to the starting candidate'
    end

    def record_failure(error)
      @receipt[:status] = case error
                          when AssertionFailure then 'failed_assertion'
                          when EnvironmentBlocker then 'blocked_environment'
                          else 'failed_harness'
                          end
      @receipt[:error] = "#{error.class}: #{error.message}"
      warn @receipt[:error]
      1
    end
  end

  module CandidateIdentity
    private

    def git(*args)
      output, status = Open3.capture2('git', '-C', @root, *args)
      raise EnvironmentBlocker, "git #{args.first} failed" unless status.success?

      output
    end

    def identity
      files = git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split("\0").uniq.sort
      content = files.map do |path|
        full_path = File.join(@root, path)
        [path, File.file?(full_path) ? Digest::SHA256.file(full_path).hexdigest : 'absent']
      end
      lock = defined?(Bundler) && Bundler.default_lockfile.to_s
      { head: git('rev-parse', 'HEAD').strip, status: git('status', '--porcelain'),
        lock_digest: lock && File.file?(lock) ? Digest::SHA256.file(lock).hexdigest : nil,
        source_digest: Digest::SHA256.hexdigest(JSON.generate(content)), root: @root }
    end
  end

  class Journey
    include DiagnosticReceipt
    include CandidateIdentity

    FIXTURE = 'spec/fixtures/incremental_runtime/hybrid_task.rb'

    def self.verify_observation!(observed, phase, generation)
      expected = { 'live' => phase, 'indexed' => phase, 'full' => phase, 'generation' => generation }
      raise AssertionFailure, "Expected #{expected.inspect}; observed #{observed.inspect}" unless expected == observed
    end

    def initialize(root:, negative_control: false)
      @root = File.realpath(root)
      @negative_control = negative_control
      FileUtils.mkdir_p(File.join(@root, 'tmp'))
      @evidence = Dir.mktmpdir('verification-', File.join(@root, 'tmp'))
      @receipt = { schema: 2, journey: 'fresh-task-indirect-job-input', started_at: Time.now.utc.iso8601,
                   negative_control: negative_control, status: 'incomplete', commands: [], observations: [],
                   limits: LIMITS }
    end

    attr_reader :evidence

    def run
      begin
        result = run_steps
      ensure
        finalize_receipt
        puts "Evidence: #{@evidence}"
      end
      @receipt[:status] == 'blocked_environment' ? 1 : result
    end

    private

    def run_steps
      @receipt[:candidate] = identity
      checkpoint!
      doctor
      Dir.mktmpdir('woods-verification-') { |fixture_root| drive(fixture_root) }
      verify_identity!

      @receipt[:status] = @negative_control ? 'negative_control_detected' : 'passed_scoped_journey'
      0
    rescue Interrupt
      @receipt[:status] = 'interrupted'
      130
    rescue StandardError => e
      record_failure(e)
    end

    def doctor
      raise EnvironmentBlocker, 'Use bundle exec with an explicit Rails appraisal' if ENV['BUNDLE_GEMFILE'].to_s.empty?

      code = <<~'CODE'
        require 'rails'; require 'sqlite3'; require 'woods'; require 'json'; require 'digest'
        root = File.realpath(Gem.loaded_specs.fetch('woods').full_gem_path)
        abort "wrong Woods source: #{root}" unless root == File.realpath(Dir.pwd)
        lock = Bundler.default_lockfile.to_s
        abort 'missing lockfile' unless File.file?(lock)
        puts JSON.generate(ruby: RUBY_DESCRIPTION, ruby_executable: RbConfig.ruby,
          rails: Rails.version, sqlite: SQLite3::VERSION, woods: Woods::VERSION, woods_root: root,
          gemfile: Bundler.default_gemfile.to_s, lock_sha256: Digest::SHA256.file(lock).hexdigest)
      CODE
      @receipt[:environment] = execute('doctor', [RbConfig.ruby, '-e', code])
    rescue CommandFailure => e
      raise EnvironmentBlocker, "Rails preflight failed: #{e.message}"
    end

    def drive(fixture_root)
      %w[before after].each_with_index do |phase, index|
        command = [RbConfig.ruby, '-Ilib']
        if @negative_control && phase == 'after'
          command += ['-r', File.join(@root, 'script/verification/skip_incremental.rb')]
        end
        observed = execute(phase, command + [FIXTURE, fixture_root, phase])
        @receipt[:observations] << observed
        checkpoint!
        if @negative_control && phase == 'after'
          verify_negative_control!(observed)
        else
          self.class.verify_observation!(observed, phase, index + 1)
        end
      end
    end

    def verify_negative_control!(observed)
      expected = { 'live' => 'after', 'indexed' => 'before', 'full' => 'after', 'generation' => 1 }
      raise HarnessError, 'Negative control did not produce the intended stale publication' unless observed == expected

      begin
        self.class.verify_observation!(observed, 'after', 2)
      rescue AssertionFailure
        return
      end
      raise HarnessError, 'Verifier accepted a stale publication'
    end

    def verify_identity!
      raise EnvironmentBlocker, 'Candidate or dependency lock changed' unless @receipt[:candidate] == identity
    end

    def execute(name, command)
      verify_identity!

      Command.new(root: @root, evidence: @evidence, commands: @receipt[:commands]).run(name, command)
    ensure
      checkpoint!
    end
  end
end
