# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require_relative '../atomic_file'
require_relative '../generation'
require_relative '../git_command'
require_relative 'index_reader'

module Woods
  module MCP
    # Explicit per-call routing of Index MCP tools to a linked worktree.
    #
    # One server process serves one index. A session whose subagents each edit
    # a different worktree needs the same tools to answer from the worktree being
    # edited, so a read tool accepts an optional `root`. Nothing is inferred:
    # without `root` the call is served exactly as before, and the caller's
    # working directory is never consulted.
    #
    # `root` must be a linked worktree of the repository the server's own index
    # describes (`git worktree list`, read through {Woods::GitCommand}). Every
    # other path is refused with a typed `invalid_params` error naming `root`.
    # A worktree's index is expected at the same location relative to the
    # worktree root as the served index is relative to its own root.
    #
    # Three parts cooperate:
    # - {Router} resolves a root to a cached {IndexReader} for that worktree.
    # - {RoutedReader} stands in for the reader the tool handlers close over, and
    #   forwards to whichever reader the in-flight call was routed to.
    # - {Dispatch} resolves `root`, strips it from the arguments, and sets the
    #   routed reader for the duration of the call.
    module WorktreeRouting
      # Tools that read the published index and so accept `root`. Pipeline,
      # feedback, snapshot and retrieval tools are bound to the launch index.
      ROOT_TOOLS = %w[
        lookup search dependencies dependents structure graph_analysis domain_clusters pagerank framework
        recent_changes trace_flow diagram woods_status
      ].freeze

      # Thread-local key holding the {Router::Route} of the in-flight call. Set
      # in {Dispatch#call_tool} and cleared in an `ensure`, because the HTTP
      # transport reuses its request threads.
      THREAD_KEY = :woods_mcp_routed_worktree

      ROOT_PROPERTY = {
        type: 'string',
        description: 'Absolute path of a linked worktree of this repository whose index answers this call. ' \
                     'Omit it to use the index this server was started with. Any other path is refused.'
      }.freeze

      # A `root` the server will not serve, with the metadata an agent branches on.
      class Refused < StandardError
        # @return [Symbol] machine-readable error code
        attr_reader :code
        # @return [Hash] extra `_meta` fields
        attr_reader :meta

        # @param message [String]
        # @param code [Symbol]
        # @param meta [Hash]
        def initialize(message, code: :invalid_params, **meta)
          super(message)
          @code = code
          @meta = meta
        end
      end

      # Resolves `root` values against the repository's linked worktrees.
      class Router
        # A worktree that may be named by `root`.
        Entry = Struct.new(:root, :index_dir, keyword_init: true)

        # @param reader [Woods::MCP::IndexReader] reader of the launch index
        # @param index_dir [String, Pathname] the launch index directory
        def initialize(reader:, index_dir:)
          @default_reader = reader
          @index_dir = index_dir
          @readers = {}
          @mutex = Mutex.new
        end

        # @return [Woods::MCP::IndexReader] the reader of the in-flight call
        def current_reader
          route = Thread.current[THREAD_KEY]
          route ? route.reader : @default_reader
        end

        # @return [String, Pathname] the index directory of the in-flight call
        def current_index_dir
          route = Thread.current[THREAD_KEY]
          route ? route.index_dir : @index_dir
        end

        # Route the calling thread to +route+ for the duration of the block.
        #
        # @param route [Route]
        # @yield the routed call
        def with_route(route)
          previous = Thread.current[THREAD_KEY]
          Thread.current[THREAD_KEY] = route
          yield
        ensure
          Thread.current[THREAD_KEY] = previous
        end

        # The worktrees `root` may name, read from Git on every call so a
        # worktree created after boot is accepted and a removed one is not.
        #
        # @return [Array<Entry>] empty when routing is unavailable
        def entries
          worktree_layout.worktrees
        end

        # Why {#entries} is empty, when it is.
        #
        # @return [String, nil]
        def unavailable_reason
          worktree_layout.reason
        end

        # @param root [Object] the caller's `root` argument
        # @return [Route] the reader and index directory serving +root+
        # @raise [Refused] when +root+ is malformed, not a worktree of this
        #   repository, or has no published index
        def resolve(root)
          real = normalize(root)
          layout = worktree_layout
          entry = layout.worktrees.find { |candidate| candidate.root == real }
          raise outside_allowlist(root, layout) unless entry

          Route.new(root: entry.root, index_dir: entry.index_dir, reader: reader_for(entry))
        end

        # Whether +entry+ is the worktree the server was launched on.
        def default?(entry)
          real(entry.index_dir) == real(@index_dir)
        end

        # The reader cached for +entry+, or nil when it has no published index.
        # Does not raise for an unextracted worktree.
        def reader_if_indexed(entry)
          reader_for(entry)
        rescue Refused
          nil
        end

        private

        Route = Struct.new(:root, :index_dir, :reader, keyword_init: true)
        private_constant :Route

        def normalize(root)
          unless root.is_a?(String) && !root.empty? && !root.include?("\0")
            raise Refused.new('`root` must be an absolute worktree path string.', argument: 'root',
                                                                                  hint: 'Pass root: "/absolute/path/to/worktree".')
          end
          unless root.start_with?('/')
            raise Refused.new("`root` must be an absolute path; got #{root.inspect}.", argument: 'root',
                                                                                       hint: 'Pass root: "/absolute/path/to/worktree".')
          end

          real(root)
        end

        def real(path)
          File.realpath(path.to_s)
        rescue SystemCallError
          File.expand_path(path.to_s)
        end

        def outside_allowlist(root, layout)
          accepted = layout.worktrees.map(&:root)
          reason = layout.reason
          message = "`root` is not a linked worktree of this repository: #{root}."
          message += " Routing is unavailable (#{reason})." if reason
          Refused.new(message, argument: 'root', accepted_roots: accepted,
                               hint: 'Pass a path listed by `git worktree list`, or omit root to use the served index.')
        end

        def reader_for(entry)
          return @default_reader if default?(entry)

          @mutex.synchronize do
            @readers[entry.index_dir] ||= build_reader(entry)
          end
        end

        def build_reader(entry)
          IndexReader.new(entry.index_dir)
        rescue ArgumentError
          raise Refused.new("No published index for worktree #{entry.root} (expected #{entry.index_dir}).",
                            code: :not_found, argument: 'root',
                            hint: 'Run `woods:extract` (or `woods:seed`) in that worktree first.')
        end

        Layout = Struct.new(:worktrees, :reason, keyword_init: true)
        private_constant :Layout

        def worktree_layout
          base = base_root
          return unavailable('no_repository') unless base

          relative = relative_index_path(base)
          return unavailable('index_dir_outside_worktree') unless relative

          listed = listed_worktrees(base)
          return unavailable('worktree_list_failed') unless listed

          Layout.new(worktrees: listed.map { |root| Entry.new(root: root, index_dir: File.join(root, relative)) })
        end

        def unavailable(reason)
          Layout.new(worktrees: [], reason: reason)
        end

        # The checkout the launch index describes: the root the index recorded,
        # when this process can reach it, otherwise the checkout containing the
        # index directory.
        def base_root
          recorded = recorded_root
          return real(recorded) if recorded && File.directory?(recorded)

          toplevel(@index_dir)
        end

        def recorded_root
          path = @default_reader.payload_dir.join('source_inputs.json')
          data = JSON.parse(AtomicFile.read(path))
          root = data.is_a?(Hash) ? data['root'] : nil
          root.is_a?(String) && root.start_with?('/') ? root : nil
        rescue StandardError
          nil
        end

        def toplevel(dir)
          return nil unless File.directory?(dir.to_s)

          out, _err, status = Open3.capture3(*GitCommand.argv(dir.to_s, 'rev-parse', '--show-toplevel'))
          status.success? && !out.strip.empty? ? real(out.strip) : nil
        rescue SystemCallError
          nil
        end

        def relative_index_path(base)
          relative = Pathname.new(real(@index_dir)).relative_path_from(Pathname.new(base)).to_s
          relative.start_with?('..') || relative == '.' ? nil : relative
        rescue ArgumentError
          nil
        end

        def listed_worktrees(base)
          out, _err, status = Open3.capture3(*GitCommand.argv(base, 'worktree', 'list', '--porcelain'))
          return nil unless status.success?

          out.split(/\n{2,}/).filter_map do |block|
            lines = block.lines.map(&:chomp)
            next if lines.any? { |line| line == 'bare' || line.start_with?('prunable') }

            path = lines.find { |line| line.start_with?('worktree ') }&.delete_prefix('worktree ')
            path && File.directory?(path) ? real(path) : nil
          end
        rescue SystemCallError
          nil
        end
      end

      # Stands in for the {IndexReader} the tool handlers close over and
      # forwards each call to the reader the in-flight request was routed to.
      class RoutedReader
        # @param router [Router]
        def initialize(router)
          @router = router
        end

        def method_missing(name, ...)
          target = @router.current_reader
          return super unless target.respond_to?(name)

          target.public_send(name, ...)
        end

        def respond_to_missing?(name, include_private = false)
          @router.current_reader.respond_to?(name, include_private) || super
        end
      end

      # Resolves `root` for the read tools, ahead of every other dispatch layer.
      module Dispatch
        def call_tool(request, **kwargs)
          router = @woods_worktree_router
          name = request[:name]
          arguments = request[:arguments]
          key = arguments.is_a?(Hash) ? [:root, 'root'].find { |candidate| arguments.key?(candidate) } : nil
          return super unless router && key && ROOT_TOOLS.include?(name)

          route = router.resolve(arguments[key])
          stripped = request.merge(arguments: arguments.reject { |candidate, _| candidate == key })
          router.with_route(route) { super(stripped, **kwargs) }
        rescue Refused => e
          refusal(name, e)
        end

        private

        def refusal(tool, error)
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: error.message }],
            error: true, structured_content: { text: error.message },
            meta: { error_code: error.code, tool: tool }.merge(error.meta)
          ).to_h
        end
      end

      class << self
        # Declare `root` on every {ROOT_TOOLS} tool the server registered. Run
        # before {ToolContract.apply!} so the schema is closed and bounded with
        # the rest of the tool's arguments.
        #
        # @param server [MCP::Server]
        # @return [MCP::Server]
        def declare_root!(server)
          server.tools.each do |name, tool|
            next unless ROOT_TOOLS.include?(name)

            schema = JSON.parse(JSON.generate(tool.input_schema_value.to_h), symbolize_names: true)
            schema[:properties] = (schema[:properties] || {}).merge(root: ROOT_PROPERTY)
            tool.input_schema(schema)
          end
          server
        end

        # Prepend {Dispatch}. Install last so it runs outside the pin and
        # validation layers: the routed reader must be set before the pin is taken.
        #
        # @param server [MCP::Server]
        # @param router [Router]
        # @return [MCP::Server]
        def install(server, router:)
          server.singleton_class.prepend(Dispatch)
          server.instance_variable_set(:@woods_worktree_router, router)
          server
        end
      end
    end
  end
end
