# frozen_string_literal: true

require 'bundler'
require 'open3'
require 'timeout'

module Woods
  module Watch
    class Installation
      # Read-only, bounded task and manager checks; never starts the watch task.
      class Probe
        PUMA_CHECK = <<~RUBY
          require 'puma'
          version = Gem.loaded_specs.fetch('puma').version
          supported = version >= Gem::Version.new('6') && version < Gem::Version.new('9') &&
                      !RUBY_PLATFORM.match?(/mswin|mingw|cygwin|java/)
          abort 'Supported Puma 6/7/8 on a native Unix Ruby is required; use external supervision' unless supported
          puts version
        RUBY

        # @param environment [Hash] selected application environment
        # @param timeout [Numeric] deadline for each task/manager probe
        def initialize(environment: ENV, timeout: 30)
          @environment = environment
          @timeout = timeout
        end

        # @param root [String] application root
        # @param child_command [Array<String>] argv ending in woods:watch
        # @param manager_command [Array<String>, nil] verified Foreman start argv
        # @param puma [Boolean] verify installed supported Puma in the application bundle
        # @return [true]
        def call(root:, child_command:, manager_command: nil, puma: false)
          output = run(root, child_command[0...-1] + ['-T', 'woods:watch'])
          unless output.match?(/\bwoods:watch\b/)
            raise Conflict, 'Selected application command does not expose woods:watch; select its Rails task entrypoint'
          end

          run(root, manager_command[0...-3] + ['--version']) if manager_command
          run(root, ['bundle', 'exec', Gem.ruby, '-e', PUMA_CHECK]) if puma
          true
        end

        private

        def run(root, command)
          environment = Bundler.unbundled_env.merge('BUNDLE_FROZEN' => 'true')
          environment['BUNDLE_GEMFILE'] = @environment.fetch('BUNDLE_GEMFILE', File.join(root, 'Gemfile'))
          environment['BUNDLE_LOCKFILE'] =
            @environment.fetch('BUNDLE_LOCKFILE', "#{environment['BUNDLE_GEMFILE']}.lock")
          Open3.popen3(environment, *command, chdir: root, pgroup: true,
                                              unsetenv_others: true) do |input, output, error, child|
            input.close
            collect(output, error, child)
          end
        rescue SystemCallError => e
          raise Conflict, "Startup preflight could not run: #{e.message}"
        end

        def collect(output, error, child)
          readers = [output, error].map { |io| Thread.new { bounded_read(io) } }
          Timeout.timeout(@timeout) do
            result, diagnostic = readers.map(&:value)
            raise Conflict, "Startup preflight failed: #{diagnostic.strip}" unless child.value.success?

            result
          end
        rescue Timeout::Error
          raise Conflict, "Startup preflight exceeded #{@timeout}s; inspect the application task command"
        ensure
          terminate(child.pid)
          readers.each(&:kill)
        end

        def bounded_read(io)
          output = String.new
          loop do
            output << io.readpartial(16_384)
            raise Conflict, 'Startup preflight exceeded 1 MiB of output' if output.bytesize > 1_048_576
          end
        rescue EOFError
          output
        end

        def terminate(pid)
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
