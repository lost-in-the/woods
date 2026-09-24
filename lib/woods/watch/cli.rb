# frozen_string_literal: true

require 'optparse'
require_relative 'supervisor'
require_relative 'claim_lease'

module Woods
  module Watch
    # Parses the foreground launcher contract without booting Rails.
    class CLI
      # @param output [#puts] diagnostic stream
      def initialize(output: $stderr)
        @output = output
      end

      # @param argv [Array<String>] launcher options and explicit child arguments
      # @return [Integer] process exit status
      def run(argv)
        options, command = parse(argv.dup)
        return 0 if @help
        return recover_claim(options, command) if @recovery_index || @claim_token

        validate_platform!
        validate_command!(command, options[:root])
        supervisor = Supervisor.new(command: command, logger: @output, **options)
        with_signals(supervisor) { supervisor.run }
      rescue OptionParser::ParseError, ArgumentError, SystemCallError, ClaimLease::Unavailable => e
        @output.puts("[woods-watch] #{e.message}")
        2
      end

      private

      def parse(argv)
        @help = false
        @recovery_index = @claim_token = nil
        options = { root: Dir.pwd, boot_timeout: 300, shutdown_timeout: 10 }
        parser = OptionParser.new do |flags|
          flags.banner = 'Usage: woods-watch [options] -- [bin/rails woods:watch]'
          flags.on('--root PATH', 'Application root (default: current directory)') do |path|
            options[:root] = File.realpath(path)
          end
          flags.on('--boot-timeout SECONDS', 'Boot/identity deadline (default: 300)') do |value|
            options[:boot_timeout] = positive_seconds(value)
          end
          flags.on('--shutdown-timeout SECONDS', 'Graceful shutdown limit (default: 10)') do |value|
            options[:shutdown_timeout] = positive_seconds(value)
          end
          recovery_options(flags)
          flags.on('-h', '--help', 'Show help without booting Rails') { @help = true }
        end
        parser.order!(argv)
        @output.puts(parser) if @help
        [options, argv.empty? && !@recovery_index && !@claim_token ? ['bin/rails', 'woods:watch'] : argv]
      end

      def recovery_options(flags)
        flags.on('--recover-claim INDEX', 'Recover an abandoned managed claim; requires --claim-token') do |path|
          @recovery_index = path
        end
        flags.on('--claim-token TOKEN', 'Exact claim token; never overrides a live owner lease') do |token|
          @claim_token = token
        end
      end

      def recover_claim(options, command)
        unless @recovery_index && @claim_token && command.empty?
          raise ArgumentError, 'use --recover-claim INDEX --claim-token TOKEN without a child command'
        end

        index = File.expand_path(@recovery_index, options[:root])
        ClaimLease.new(index).recover(token: @claim_token)
        @output.puts("[woods-watch] recovered the selected abandoned claim at #{index}; restart its normal owner")
        0
      end

      def positive_seconds(value)
        number = Float(value)
        return number if number.finite? && number.positive?

        raise ArgumentError, 'timeout must be a positive finite number of seconds'
      rescue ArgumentError, TypeError
        raise ArgumentError, 'timeout must be a positive finite number of seconds'
      end

      def validate_platform!
        return if Process.respond_to?(:fork) && !RUBY_PLATFORM.match?(/mswin|mingw|java/)

        raise ArgumentError,
              'managed watching requires POSIX process groups and fork; use an external raw-task supervisor'
      end

      def validate_command!(command, root)
        executable = command.first
        paths = if executable.include?(File::SEPARATOR)
                  [File.expand_path(executable, root)]
                else
                  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map do |entry|
                    File.expand_path(File.join(entry, executable), root)
                  end
                end
        return if paths.any? { |path| File.file?(path) && File.executable?(path) }

        raise ArgumentError, "child executable not found or not executable: #{executable}"
      end

      def with_signals(supervisor)
        handlers = %w[INT TERM].to_h { |signal| [signal, Signal.trap(signal) { supervisor.stop }] }
        yield
      ensure
        handlers&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
  end
end
