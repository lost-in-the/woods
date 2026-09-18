# frozen_string_literal: true

require 'optparse'
require 'tempfile'
require 'base64'
require 'securerandom'
require 'woods/source_inputs/scanner'
require 'woods/source_inputs/handoff'
require 'woods/hooks/refresh'

module Woods
  module SourceInputs
    # Captures before a fresh child evaluates Bundler, the Rakefile and Rails.
    # The parent waits so all exit paths can remove the private handoff.
    class Launcher # rubocop:disable Metrics/ClassLength -- parser and child lifetime form one CLI contract
      OPERATIONS = %w[full incremental refresh].freeze

      def self.run(argv, **options)
        new(argv, **options).run
      rescue OptionParser::ParseError, ArgumentError, PrivateKey::Unavailable, SystemCallError => e
        warn "woods-extract: #{e.message}"
        1
      end

      def initialize(argv, command: %w[bundle exec rake])
        @arguments = argv.dup
        @command = command
        @original_directory = Dir.pwd
        @root = @original_directory
        @output = ENV.fetch('WOODS_OUTPUT', 'tmp/woods')
        @extra_roots = []
        parse!
      end

      def run # rubocop:disable Metrics/MethodLength -- handoff lifetime encloses the fresh child
        return 0 if @help

        operation, task = task_for_arguments
        key = PrivateKey.new(output_dir: @output, create: true)
        rules = Scopes.new(extra_roots: @extra_roots)
        snapshot = Scanner.new(root: @root, output_dir: @output, key: key, scopes: rules).call
        nonce = SecureRandom.hex(32)
        Tempfile.create(['woods-source-capture-', '.json']) do |file|
          file.binmode
          file.chmod(0o600)
          file.write(JSON.generate(version: 1, nonce: nonce, root: @root, output: @output,
                                   operation: operation, rules: rules.fingerprint,
                                   launcher_pid: Process.pid, snapshot: snapshot))
          file.flush
          file.fsync
          descriptor = JSON.generate(path: file.path, nonce: nonce, extra_roots: @extra_roots)
          environment = { Handoff::ENV_KEY => descriptor, 'WOODS_OUTPUT' => @output }
          if ENV['BUNDLE_GEMFILE']
            environment['BUNDLE_GEMFILE'] = File.expand_path(ENV.fetch('BUNDLE_GEMFILE'), @original_directory)
          end
          run_child(environment, task)
        end
      end

      private

      def parse!
        parser.permute!(@arguments)
        validate_arguments! unless @help
      end

      def parser
        OptionParser.new do |options|
          options.banner = 'Usage: woods-extract [options] full | incremental PATH... | refresh TYPE...'
          options.on('--root PATH', 'Application root (default: current directory)') { |path| @root = path }
          options.on('--output PATH', 'Index output (default: WOODS_OUTPUT or tmp/woods)') { |path| @output = path }
          options.on('--source-root PATH', 'Additional application-relative runtime source root') do |path|
            @extra_roots << path
          end
          options.on('-h', '--help', 'Show usage') do
            puts options
            @help = true
          end
        end
      end

      def validate_arguments!
        @root = File.expand_path(@root)
        raise ArgumentError, 'application root does not exist' unless File.directory?(@root)

        @output = File.expand_path(@output, @root)
        @operation = @arguments.shift
        raise ArgumentError, 'choose full, incremental, or refresh' unless OPERATIONS.include?(@operation)
        if @operation == 'full' && !@arguments.empty?
          raise ArgumentError,
                'full does not accept paths or extractor names'
        end
        if @operation != 'full' && @arguments.empty?
          raise ArgumentError,
                "#{@operation} requires paths or extractor names"
        end

        @extra_roots = Scopes.new(extra_roots: @extra_roots).extra_roots
      end

      def task_for_arguments
        return ['full', 'woods:extract'] if @operation == 'full'
        return refresh_task if @operation == 'refresh'

        incremental_task
      end

      def incremental_task
        paths = @arguments.map { |path| relative_path(path) }.uniq
        action = InputRules.new
        operation = paths.any? { |path| action.action(path) == :full } ? 'full' : 'incremental'
        if paths.size > Hooks::Refresh::MAX_EVENTS
          raise ArgumentError, 'too many incremental paths; split the input or run full'
        end

        batch = Base64.strict_encode64(JSON.generate(version: 1, output: @output,
                                                     events: paths.map { |path| { path: path, operation: 'update' } }))
        raise ArgumentError, 'incremental batch too large; split the input or run full' if batch.bytesize > 120_000

        [operation, "woods:hook_refresh[#{batch}]"]
      end

      def refresh_task
        names = @arguments.uniq
        unless names.all? { |name| name.match?(/\A[a-z_]+\z/) && Extractor::EXTRACTORS.key?(name.to_sym) }
          raise ArgumentError, 'refresh requires known extractor names'
        end

        ['refresh', "woods:refresh[#{names.join(',')}]"]
      end

      def relative_path(path)
        absolute = File.expand_path(path, @root)
        unless absolute.start_with?("#{@root}/") && !path.include?("\0")
          raise ArgumentError, 'incremental paths must be inside the application root'
        end

        absolute.delete_prefix("#{@root}/")
      end

      def run_child(environment, task)
        pid = Process.spawn(environment, *@command, task, chdir: @root, pgroup: true)
        previous = %w[INT TERM].to_h do |signal|
          [signal, Signal.trap(signal) do
            Process.kill(signal, -pid)
          rescue StandardError
            nil
          end]
        end
        _finished, status = Process.wait2(pid)
        status.exitstatus || (128 + status.termsig)
      ensure
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
  end
end
