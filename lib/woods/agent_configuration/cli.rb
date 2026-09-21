# frozen_string_literal: true

require_relative 'cli_options'
require_relative 'plan_diff'
require_relative 'layout'
require_relative 'launcher'
require_relative 'preflight'
require_relative 'planner'
require_relative 'applier'

module Woods
  module AgentConfiguration
    class CLI
      def initialize(stdout: $stdout, stderr: $stderr, preflight: Preflight.new)
        @stdout = stdout
        @stderr = stderr
        @preflight = preflight
      end

      def run(argv)
        options = { root: Dir.pwd, index: 'tmp/woods', mode: 'host', name: 'woods' }
        command = argv.shift
        parser = CLIOptions.build(options)
        parser.parse!(argv)
        if options[:help] || command.nil? || %w[-h --help].include?(command)
          @stdout.puts(parser)
          return 0
        end
        layout = Layout.new(root: options.fetch(:root), scope: options[:scope], client: options[:client])
        result = dispatch(command, argv, options, layout)
        @stdout.puts(JSON.pretty_generate(result))
        0
      rescue Conflict, OptionParser::ParseError, SystemCallError => e
        @stderr.puts("woods-agent-config: #{e.message}")
        1
      end

      private

      def dispatch(command, argv, options, layout)
        case command
        when 'setup', 'update', 'remove'
          raise Conflict, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?

          create_plan(command, options, layout)
        when 'show', 'apply'
          consume_plan(command, argv, options, layout)
        when 'recover'
          raise Conflict, 'Recover does not accept positional arguments' unless argv.empty?

          { 'result' => Applier.new(layout: layout).recover }
        else
          raise Conflict, 'Select setup, update, remove, show, apply, or recover'
        end
      end

      def consume_plan(command, argv, options, layout)
        raise Conflict, 'Select exactly one saved plan file' unless argv.size == 1

        plan = Plan.load(argv.first).validate!(layout)
        return { 'result' => Applier.new(layout: layout).apply(plan) } if command == 'apply'

        PlanDiff.show(plan, @stderr) if options[:diff]
        plan.summary
      end

      def create_plan(operation, options, layout)
        path = options[:plan]
        raise Conflict, 'Choose --plan FILE for the private, reviewable write plan' unless path

        launcher = if operation != 'remove'
                     Launcher.new(root: layout.root, **options.slice(:index, :mode, :service, :container_root))
                   end
        evidence = launcher ? @preflight.call(launcher) : {}
        plan = Planner.new(layout: layout, operation: operation, entry: launcher&.entry,
                           name: options.fetch(:name), instructions: options[:instructions],
                           evidence: evidence, intent: launcher ? launcher.intent : {}).call
        write_plan(path, plan, layout)
        PlanDiff.show(plan, @stderr) if options[:diff]
        plan.summary.merge('plan_file' => File.expand_path(path),
                           'runtime_files' => layout.runtime_paths)
      end

      def write_plan(path, plan, layout)
        target = File.expand_path(path)
        protected_paths = layout.allowed_paths + layout.runtime_paths
        raise Conflict, 'Plan output must differ from every managed/runtime target' if protected_paths.include?(target)

        Document.validate_path!(target)
        content = "#{JSON.pretty_generate(plan.data)}\n"
        raise Conflict, 'Plan exceeds the supported size' if content.bytesize > Document::MAX_BYTES

        File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.write(content)
          file.flush
          file.fsync
        end
      end
    end
  end
end
