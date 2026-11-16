# frozen_string_literal: true

require_relative 'cli_options'
require_relative 'plan_diff'
require_relative 'layout'
require_relative 'launcher'
require_relative 'preflight'
require_relative 'planner'
require_relative 'applier'
require_relative 'entry_form'

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

        launcher, form, note = build_launcher(layout, options) if operation != 'remove'
        evidence = launcher ? @preflight.call(launcher) : {}
        planner = Planner.new(layout: layout, operation: operation, entry: launcher&.entry,
                              name: options.fetch(:name), instructions: options[:instructions],
                              evidence: evidence, intent: launcher ? launcher.intent : {})
        plan = planner.call
        write_plan(path, plan, layout)
        PlanDiff.show(plan, @stderr) if options[:diff]
        plan.summary.merge('plan_file' => File.expand_path(path), 'runtime_files' => layout.runtime_paths)
            .merge(outcome(layout, launcher, form, note, planner)).compact
      end

      def outcome(layout, launcher, form, form_note, planner)
        { 'entry_form' => form, 'adopted' => (true if planner.adopted?),
          'notes' => notes(layout, launcher, form_note, planner) }
      end

      # What the plan cannot do itself and the user should know.
      def notes(layout, launcher, form_note, planner)
        return if launcher.nil?

        list = [form_note]
        if planner.adopted?
          list << 'adopted the existing woods entry, identical to what setup writes; ' \
                  'this checkout now has its own receipt'
        end
        if layout.scope == 'project'
          list << '.woods-agent-config.json records this machine\'s root and paths: add it to .gitignore ' \
                  'and commit .mcp.json'
        end
        if launcher.form == 'relative' && launcher.mode == 'compose'
          list << "the #{launcher.service} service's working_dir must be the application root inside the " \
                  'container (the preflight ran there, as the entry will), and a linked worktree reaches the ' \
                  'running service only when the Compose project name is pinned (a top-level `name:` or ' \
                  'COMPOSE_PROJECT_NAME)'
        end
        list.compact
      end

      def build_launcher(layout, options)
        form, note = EntryForm.choose(layout, options[:entry_form])
        launcher = Launcher.new(root: layout.root, form: form,
                                **options.slice(:index, :mode, :service, :container_root))
        [launcher, form, note]
      end

      def write_plan(path, plan, layout)
        target = File.expand_path(path)
        protected_paths = layout.allowed_paths + layout.runtime_paths
        raise Conflict, 'Plan output must differ from every managed/runtime target' if protected_paths.include?(target)

        Plan.validate_path!(target)
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
