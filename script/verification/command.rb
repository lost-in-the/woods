# frozen_string_literal: true

require 'json'
require 'timeout'

module WoodsVerification
  class EvidenceError < StandardError; end
  class AssertionFailure < EvidenceError; end
  class EnvironmentBlocker < EvidenceError; end
  class HarnessError < EvidenceError; end
  class CommandFailure < HarnessError; end

  # Own and reap only the process group created for this verification command.
  class Command
    def initialize(root:, evidence:, commands:, timeout: 180)
      @root = root
      @evidence = evidence
      @commands = commands
      @timeout = timeout
    end

    def run(name, command)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = { name: name, argv: command, stdout: File.join(@evidence, "#{name}.stdout"),
                stderr: File.join(@evidence, "#{name}.stderr") }
      @commands << entry
      status = invoke(command, entry)
      raise CommandFailure, "#{name} exited #{status.exitstatus}; see retained logs" unless status.success?

      JSON.parse(File.readlines(entry[:stdout]).last || '')
    rescue JSON::ParserError => e
      raise HarnessError, "#{name} did not emit valid JSON evidence: #{e.message}"
    rescue Errno::ENOENT, Errno::EACCES => e
      raise EnvironmentBlocker, "#{name} could not run: #{e.message}"
    ensure
      entry[:elapsed_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started if entry
    end

    private

    def invoke(command, entry)
      pid = Process.spawn({ 'BUNDLE_FROZEN' => 'true', 'RAILS_ENV' => 'test' }, *command,
                          chdir: @root, out: entry[:stdout], err: entry[:stderr], pgroup: true)
      _, status = Timeout.timeout(@timeout) { Process.wait2(pid) }
      entry[:exit_status] = status.exitstatus
      status
    rescue Timeout::Error
      entry[:timed_out] = true
      raise CommandFailure, "#{entry[:name]} exceeded #{@timeout} seconds"
    rescue Interrupt
      entry[:interrupted] = true
      raise
    ensure
      stop_and_reap(pid) if pid && !status
    end

    def stop_and_reap(pid)
      begin
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        # Already exited; still attempt to reap it.
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        # Already reaped.
      end
    end
  end
end
