# frozen_string_literal: true

require_relative '../ast/parser'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    # Raised when EvalGuard rejects a `console_eval` payload.
    class ForbiddenExpressionError < Woods::Error; end

    # Parse-time refusal layer for `console_eval`.
    #
    # ## Reachability (v0.2)
    #
    # EvalGuard is the first of five controls on the embedded `console_eval`
    # opt-in path. `EmbeddedExecutor#handle_eval` calls `check!` before
    # anything else — ahead of the Confirmation prompt, the SafeContext
    # rollback, the timeout, and the audit log. When the opt-in is off
    # (the default), `refusal_for('eval')` still short-circuits with the
    # `eval_disabled` payload and this guard is not reached. See
    # docs/CONSOLE_MCP_SETUP.md "console_eval opt-in" and backlog B-053.
    #
    # Bridge-process mode (in development) will call the same guard before
    # shipping the payload to the remote Rails worker.
    #
    # ## Behaviour
    #
    # Walks the normalized {Woods::Ast::Parser} tree of the proposed Ruby
    # snippet and refuses any expression that reaches a known credential or
    # reflection escape — so an LLM-generated `Rails.application.credentials
    # .stripe.secret_key` or a reflection escape is rejected before the bridge
    # ever sees it.
    #
    # This is defense in depth, not the only line: the bridge process must
    # re-enforce the same rules at execution time. The gem-side check exists
    # so the LLM sees a fast, visible refusal instead of relying on the host
    # app's bridge configuration.
    #
    # @example
    #   EvalGuard.check!('User.count')                                # => true
    #   EvalGuard.check!('Rails.application.credentials.stripe.key')  # raises
    #
    class EvalGuard # rubocop:disable Metrics/ClassLength
      # Receivers/calls whose presence in the AST is always a refusal.
      # Each entry is matched against the dotted source text of every send
      # node's receiver (and qualified call name) — so a denial of
      # `Rails.application.credentials` catches every chained access through it
      # (e.g. `Rails.application.credentials.dig(:stripe)`).
      DENIED_CALL_CHAINS = %w[
        Rails.application.credentials
        Rails.application.secrets
        Rails::Secrets
        Devise.secret_key
      ].freeze

      # Constants whose bare reference (or use as a receiver) is denied.
      #
      # - `ENV` — reads host secrets as a string-keyed hash.
      # - Threading: `Thread`, `Fiber`, `Ractor`, `Process` — concurrent
      #   execution escapes the rolled-back transaction (the spawned block
      #   leases its own connection outside SafeContext's tx).
      # - Deserialization: `Marshal`, `YAML`, `Psych` — unsafe load paths
      #   can execute arbitrary code during object instantiation.
      # - Network: `Net`, `Socket`, `TCPSocket`, `UDPSocket`, `URI`,
      #   `OpenURI`, `Resolv`, `Faraday`, `HTTP` — every HTTP/network egress
      #   point available in a standard Rails install.
      # - File I/O: `File`, `FileUtils`, `IO`, `Dir`, `Pathname`,
      #   `Tempfile`, `StringIO`, `BasicObject` — broad filesystem access.
      # - Kernel-ish: `Kernel`, `Object`, `ObjectSpace`, `GC`,
      #   `RubyVM`, `TracePoint`, `Gem`, `Bundler`.
      # File/IO/Pathname are intentionally NOT in this list — legitimate
      # non-credential file reads are a core use case. Credential-path
      # access is handled by CREDENTIAL_FILE_READERS below, and shell-exec
      # attempts (`Kernel.open("|cmd")`, backticks, `%x{}`) are caught by
      # the backtick textual check in #check! and the DENIED_REFLECTION
      # entries for `system`/`exec`/`popen`/etc.
      DENIED_CONSTANTS = %w[
        ENV
        Thread Fiber Ractor Process Mutex ConditionVariable Queue SizedQueue
        Marshal YAML Psych
        Net Socket TCPSocket UDPSocket UNIXSocket URI OpenURI Resolv Faraday HTTP
        ObjectSpace GC RubyVM TracePoint
        Gem Bundler
      ].freeze

      # Method names that escape the AST sandbox regardless of receiver.
      #
      # Covers, in order:
      # - Eval family: the classic `eval`/`instance_eval`/`class_eval`/
      #   `module_eval` plus `binding` (which enables reconstructing an eval
      #   in the caller's scope).
      # - Dynamic dispatch: `send` / `public_send` / `__send__` / `method` /
      #   `public_method` (returns a callable, indirect dispatch) and the
      #   `const_get` / `const_set` / `remove_const` / `define_method` /
      #   `define_singleton_method` / `alias_method` / `undef_method` /
      #   `remove_method` / `method_defined?` / `prepend` / `include_module`
      #   reflection family.
      # - State mutation: `instance_variable_set` / `instance_variable_get`,
      #   `class_variable_set` / `class_variable_get` / `freeze` / `taint`.
      # - Object-space escapes: `_id2ref`, `each_object`, `const_source_location`.
      # - System / process: `system`, `exec`, `spawn`, `fork`, `popen`, `%x{}`
      #   (AST method name `backtick` / xstr) so they can't be invoked
      #   implicitly.
      # - File / IO: `open` (bare Kernel#open — the File-specific reader is
      #   handled separately via CREDENTIAL_FILE_READERS, but the bare
      #   `Kernel.open("|shell-command")` form is how most shellshock-style
      #   escapes slip through).
      # - Network: `URI.open` (when called as `open` on URI, the AST method
      #   name is `open` so the string match above catches it). HTTP / Socket
      #   constants are denied separately via DENIED_CONSTANTS.
      # - Loader: `load`, `require`, `require_relative`, `autoload`.
      # - Unsafe deserialization: `unsafe_load` / `_load` (Marshal.load and
      #   YAML.load are denied via DENIED_CONSTANTS + method gate below).
      # - Threading escapes from SafeContext's rollback: `new` on Thread /
      #   Fiber / Process is denied via DENIED_CONSTANTS so the
      #   {Kernel.fork, Thread.new} pair can't slip past.
      DENIED_REFLECTION = %w[
        eval instance_eval class_eval module_eval binding
        instance_exec class_exec module_exec
        send public_send __send__ method public_method
        const_get const_set remove_const define_method define_singleton_method
        alias_method undef_method remove_method method_defined? singleton_method
        instance_variable_get instance_variable_set
        class_variable_get class_variable_set
        _id2ref each_object const_source_location instance_variables
        prepend include_module
        system exec spawn fork popen popen2 popen2e popen3 backtick
        require require_relative autoload
        unsafe_load _load
        taint untaint
      ].freeze

      # Receivers + method-name pairs that read credential files from disk.
      # Triggers when the receiver matches AND any literal argument source
      # contains a known credential path fragment. `Pathname.new(...)` is
      # included so `Pathname.new(...).read` chains are caught at construction.
      #
      # `open` is included for File and IO to catch chained patterns like
      # `File.open("config/master.key").read` — the inner `File.open(path)`
      # node is visited by `scan_send_nodes` and refused here before the
      # outer `.read` call is even examined (PR #34 review medium #3).
      CREDENTIAL_FILE_READERS = {
        'File' => %w[read binread readlines open],
        'IO' => %w[read binread readlines open],
        'Pathname' => %w[read binread new open]
      }.freeze
      CREDENTIAL_PATH_HINTS = %w[
        master.key credentials.yml.enc credentials/
        secrets.yml secrets.yml.enc
      ].freeze

      class << self
        # @param code [String] Ruby source proposed for `console_eval`.
        # @raise [ForbiddenExpressionError] on any denial or parse failure.
        def check!(code)
          new.check!(code)
        end
      end

      def initialize(parser: Woods::Ast::Parser.new)
        @parser = parser
      end

      # Textual token for class-variable (`@@foo = …`) and global-variable
      # (`$foo = …`) assignments. {Woods::Ast::Parser} doesn't normalize
      # cvasgn / gvasgn to a dedicated node type, so we catch them at the
      # source level the same way shell-execution literals are caught.
      # Instance-variable writes (`@foo = …`) ARE normalized to `:ivasgn`
      # and are refused via the AST walk — see {#scan_assignment_nodes}.
      CLASS_OR_GLOBAL_VAR_ASSIGNMENT = /
        (?:^|[^\w])         # not mid-identifier
        (@@\w+|\$\w+)       # @@cvar or $gvar
        \s*=(?!=)           # single `=`, not `==`
      /x
      private_constant :CLASS_OR_GLOBAL_VAR_ASSIGNMENT

      # @param code [String]
      # @raise [ForbiddenExpressionError]
      def check!(code)
        raise ForbiddenExpressionError, 'payload is empty' if code.nil? || code.strip.empty?

        # Fail-safe textual check for backtick literals (` `cmd` ` and
        # `%x{cmd}`) — the AST flavor of these is `:xstr`/`:xstr_heredoc`,
        # which {Woods::Ast::Parser} may normalize differently across
        # Prism/parser-gem backends. A source-level refusal is both cheap
        # and impossible to evade via AST normalization.
        if code.include?('`') || code =~ /%x[{<|!@#(\[]/
          raise ForbiddenExpressionError, 'payload contains a shell-execution literal (backtick or %x)'
        end

        refuse_class_or_global_var_assignment!(code)

        tree = parse_or_refuse(code)
        scan_send_nodes(tree)
        scan_const_nodes(tree)
        scan_assignment_nodes(tree)
      end

      private

      def parse_or_refuse(code)
        @parser.parse(code)
      rescue Woods::ExtractionError => e
        raise ForbiddenExpressionError, "payload could not be parsed safely: #{e.message}"
      end

      def scan_send_nodes(tree)
        tree.find_all(:send).each do |node|
          refuse_reflection!(node)
          refuse_denied_constant_receiver!(node)
          refuse_denied_constant_in_args!(node)
          refuse_denied_call_chain!(node)
          refuse_credential_file_read!(node)
        end
      end

      def scan_const_nodes(tree)
        tree.find_all(:const).each do |node|
          if DENIED_CONSTANTS.include?(node.method_name.to_s)
            raise ForbiddenExpressionError,
                  "payload references denied constant #{node.method_name}"
          end
        end
      end

      # Refuse `@ivar = …` writes. The embedded `console_eval` path runs
      # inside a throwaway receiver, so a payload setting `@audit_logger
      # = nil` would only affect the throwaway — but we deny the syntactic
      # form anyway as defense-in-depth for any future caller that might
      # hand EvalGuard a payload evaluated in a non-isolated binding.
      def scan_assignment_nodes(tree)
        node = tree.find_all(:ivasgn).first
        return unless node

        raise ForbiddenExpressionError,
              "payload writes to instance variable #{node.method_name}"
      end

      # Textual refusal for `@@cvar = …` / `$gvar = …`. The parser
      # normalization doesn't distinguish cvasgn / gvasgn today; the
      # source-level scan is the same shape as the backtick check above.
      def refuse_class_or_global_var_assignment!(code)
        return unless (match = CLASS_OR_GLOBAL_VAR_ASSIGNMENT.match(code))

        raise ForbiddenExpressionError,
              "payload writes to #{match[1]} (class/global variable assignment)"
      end

      def refuse_reflection!(node)
        return unless DENIED_REFLECTION.include?(node.method_name.to_s)

        raise ForbiddenExpressionError,
              "payload calls reflection method `#{node.method_name}`"
      end

      def refuse_denied_constant_receiver!(node)
        return unless node.receiver && DENIED_CONSTANTS.include?(node.receiver.to_s)

        raise ForbiddenExpressionError,
              "payload references denied constant #{node.receiver}"
      end

      # Catches `puts ENV` — Prism flattens method-call argument nodes into
      # source-text strings, so a bare ENV passed as an argument never appears
      # as its own :const node. Match it as a whole-word token in arg text.
      def refuse_denied_constant_in_args!(node)
        DENIED_CONSTANTS.each do |const|
          pattern = /\b#{Regexp.escape(const)}\b/
          next unless Array(node.arguments).any? { |arg| arg.to_s.match?(pattern) }

          raise ForbiddenExpressionError,
                "payload references denied constant #{const}"
        end
      end

      def refuse_denied_call_chain!(node)
        qualified = qualified_call(node)
        DENIED_CALL_CHAINS.each do |chain|
          next unless qualified.include?(chain)

          raise ForbiddenExpressionError,
                "payload references denied call chain `#{chain}`"
        end
      end

      def refuse_credential_file_read!(node)
        receiver = node.receiver.to_s
        return unless CREDENTIAL_FILE_READERS.key?(receiver)
        return unless CREDENTIAL_FILE_READERS.fetch(receiver).include?(node.method_name.to_s)
        return unless Array(node.arguments).any? { |arg| credential_path?(arg) }

        raise ForbiddenExpressionError,
              "payload reads credential file via `#{receiver}.#{node.method_name}`"
      end

      def qualified_call(node)
        return node.method_name.to_s unless node.receiver

        "#{node.receiver}.#{node.method_name}"
      end

      def credential_path?(arg_text)
        text = arg_text.to_s
        CREDENTIAL_PATH_HINTS.any? { |hint| text.include?(hint) }
      end
    end
  end
end
