# frozen_string_literal: true

require 'pathname'
require 'shellwords'
require_relative 'served_identity'

module Woods
  module MCP
    # The checkout-aware Index Server entry for a project's MCP client
    # configuration: no absolute path and no `cwd`, so one committed file
    # serves every checkout and worktree on every machine. The install
    # generator prints it and `woods-agent-config` writes it, from here only.
    #
    # The launch runs through `sh` for four reasons:
    #
    # - Claude Code sets `CLAUDE_PROJECT_DIR` (the project root) only in the
    #   spawned server's environment and leaves the server's working directory
    #   undocumented; the entry changes into that directory when it is set,
    #   and otherwise starts where the client starts it.
    # - An application below its checkout root needs its own directory, where
    #   its Gemfile is: Bundler looks up from the working directory, never
    #   down. The entry changes into it from the checkout root
    #   (`git rev-parse --show-toplevel`), wherever in the checkout it starts.
    # - A container that cannot see the client root (no mount map) cannot
    #   tell a session in a linked worktree from one in the checkout it
    #   mounts. The container entry hands over what the client's checkout is,
    #   with no path in it (`--client-identity`), and the server refuses a
    #   checkout that differs from the one it serves.
    # - Claude Code rewrites `${NAME}` and `${NAME:-default}` in `args` from
    #   its own environment before the server runs, so the shell reads every
    #   variable it needs as `$NAME`. The entry never contains `${`.
    #
    # `woods-mcp-start --checkout` then serves the index of the checkout it
    # starts in, and `--await-index` starts before that index exists.
    module ClientEntry
      LAUNCH = 'bundle exec woods-mcp-start --checkout --await-index'

      PROJECT_DIRECTORY = 'if [ -n "$CLAUDE_PROJECT_DIR" ]; then cd "$CLAUDE_PROJECT_DIR" || exit 1; fi; '

      # What the client's checkout is, with no path in it, for a container
      # that cannot see the client root: `main|linked:HEAD:branch`. A linked
      # worktree's `.git` is a file; the main checkout's is a directory.
      CLIENT_IDENTITY = 'id="$(test -f "$(git rev-parse --show-toplevel 2>/dev/null)/.git" ' \
                        '&& echo linked || echo main):$(git rev-parse --verify -q HEAD 2>/dev/null)' \
                        ':$(git branch --show-current 2>/dev/null)"; '

      # Where an application sits in its checkout.
      Location = Struct.new(:application, :output, keyword_init: true)

      module_function

      # @param root [String] the application root
      # @param service [String, nil] see {.checkout}
      # @param index [String] the index directory relative to +root+
      # @return [Hash] the entry for the application at +root+
      # @raise [ArgumentError] when +root+ is not inside a git checkout
      def for_root(root, service: nil, index: 'tmp/woods')
        location = locate(root, index: index)
        checkout(service: service, application: location.application, output: location.output)
      end

      # @param service [String, nil] a Docker Compose service to launch in;
      #   nil for a host launch. The caller validates the name.
      # @param application [String, nil] the application directory relative
      #   to the checkout root, when it is below that root
      # @param output [String, nil] the index directory relative to the
      #   checkout root, when it is not `tmp/woods` there
      # @return [Hash] a stdio server entry
      def checkout(service: nil, application: nil, output: nil)
        start = PROJECT_DIRECTORY
        start += %(cd "$(git rev-parse --show-toplevel)"/#{Shellwords.escape(application)} || exit 1; ) if application
        unless service
          entry = { 'type' => 'stdio', 'command' => 'sh', 'args' => ['-c', "#{start}exec #{LAUNCH}"] }
          return output ? entry.merge('env' => { 'WOODS_OUTPUT' => output }) : entry
        end

        map = ServedIdentity::CLIENT_ROOT_MAP_ENV
        settings = "-e #{map}=\"$#{map}\"#{" -e WOODS_OUTPUT=#{Shellwords.escape(output)}" if output}"
        { 'type' => 'stdio', 'command' => 'sh',
          'args' => ['-c', "#{start}#{CLIENT_IDENTITY}exec docker compose exec -T #{settings} #{service} " \
                           "#{LAUNCH} --client-root \"$PWD\" --client-identity \"$id\""] }
      end

      # Where `--checkout` must look for the index of an application at
      # +root+, and which directory the launch must start in.
      #
      # @param root [String] the application root
      # @param index [String] the index directory relative to +root+
      # @return [Location] nil fields for an application at the checkout root
      #   with its index at `tmp/woods`
      # @raise [ArgumentError] when +root+ is not inside a git checkout
      def locate(root, index: 'tmp/woods')
        checkout = ServedIdentity.checkout_root(root)
        raise ArgumentError, "#{root} is not inside a git checkout" unless checkout

        below = Pathname.new(File.realpath(root)).relative_path_from(Pathname.new(checkout)).to_s
        output = Pathname.new(below == '.' ? index : File.join(below, index)).cleanpath.to_s
        Location.new(application: (below unless below == '.'), output: (output unless output == 'tmp/woods'))
      end
    end
  end
end
