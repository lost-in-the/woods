# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'
require 'bundler'
require_relative 'error'

module Woods
  module AgentConfiguration
    class Preflight
      REQUIRED_TOOLS = %w[woods_status search lookup dependencies dependents].freeze
      SCRIPT = <<~'RUBY'
        require 'timeout'
        Timeout.timeout(25) do
          require 'json'
          require 'woods'
          require 'woods/mcp/server'
          require 'woods/resilience/index_validator'
          root = File.realpath(ARGV.fetch(1))
          index = File.realpath(ARGV.fetch(0))
          spec = Gem.loaded_specs.fetch('woods')
          abort 'Installed Woods is missing woods-mcp-start' unless spec.executables.include?('woods-mcp-start')
          reader = Woods::MCP::IndexReader.new(index)
          manifest = reader.manifest
          abort 'Published extraction manifest missing or malformed' unless manifest.is_a?(Hash) && manifest['counts'].is_a?(Hash)
          report = Woods::Resilience::IndexValidator.new(index_dir: index, app_root: root).validate
          abort report.errors.join("\n") unless report.valid?
          tools = Woods::MCP::Server.build(index_dir: index, warmup: false).tools.keys
          puts JSON.generate(version: Woods::VERSION, tools: tools.sort, root: root, index: index,
                             generation: reader.loaded_generation, warnings: report.warnings)
        end
      RUBY

      def initialize(timeout: 30)
        @timeout = timeout
      end

      def call(launcher)
        output = run(launcher)
        evidence = JSON.parse(output)
        raise Conflict, 'Installed Woods preflight expected a JSON object' unless evidence.is_a?(Hash)

        missing = REQUIRED_TOOLS - Array(evidence['tools'])
        raise Conflict, "Installed Woods lacks required Index capabilities: #{missing.join(', ')}" unless missing.empty?
        raise Conflict, 'Installed Woods did not report its version' unless evidence['version'].is_a?(String)

        evidence
      rescue JSON::ParserError
        raise Conflict, 'Installed Woods preflight did not return valid JSON; inspect application bundle and index'
      end

      private

      def run(launcher)
        command = launcher.probe_command(SCRIPT)
        environment = Bundler.unbundled_env.merge(launcher.probe_environment)
        Open3.popen3(environment, *command, chdir: launcher.root, unsetenv_others: true,
                                            pgroup: true) do |stdin, out, err, wait|
          stdin.close
          collect(out, err, wait)
        end
      rescue Errno::ENOENT => e
        raise Conflict, "Launch command unavailable: #{e.message}"
      end

      def collect(stdout, stderr, wait)
        readers = [stdout, stderr].map { |stream| Thread.new { bounded_read(stream) } }
        Timeout.timeout(@timeout) do
          output, errors = readers.map(&:value)
          raise Conflict, "Installed Woods preflight failed: #{errors.strip}" unless wait.value.success?

          output
        end
      rescue Timeout::Error
        raise Conflict, "Installed Woods preflight exceeded #{@timeout}s; verify the selected command and container"
      ensure
        terminate(wait.pid)
        readers&.each(&:kill)
      end

      def bounded_read(stream)
        output = String.new
        loop do
          chunk = stream.readpartial(16_384)
          output << chunk
          raise Conflict, 'Installed Woods preflight output exceeded 1 MiB' if output.bytesize > 1_048_576
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
