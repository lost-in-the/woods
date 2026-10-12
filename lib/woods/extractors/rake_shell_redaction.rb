# frozen_string_literal: true

require 'strscan'
require_relative 'config_source_guard'

module Woods
  module Extractors
    # Redacts credentials in a shell command line before it is published as
    # `metadata.shell_commands`.
    #
    # {ConfigSourceGuard.redact} runs first: known credential shapes, URL
    # userinfo and private keys. Then the line is read as shell arguments (a
    # quoted value with spaces is one argument) and the pass withholds what a
    # command line carries that Ruby source does not:
    #
    # * `NAME=value`, `--name=value` and `--name value`, when the name is
    #   credential-named (any value) or sensitive-named (a value that reads
    #   as a generated token). A `$VAR` or `#{...}` value is a reference and
    #   is kept.
    # * The value after `Bearer` or `Basic`, and of a credential-named header
    #   (`X-Api-Key: ...`, `X-Api-Key:...`).
    # * The password half of `-u user:password`, `-uuser:password` and
    #   `--user=user:password`.
    # * The password flag of tools that take one (`mysql -p...`,
    #   `sshpass -p ...`, `docker login -p ...`, `redis-cli -a ...`), unless the
    #   value reads as a port.
    # * Credential-named query parameters (`?token=...`), and credential
    #   literals inside a quoted argument (a JSON body).
    #
    # Arguments are scanned with possessive patterns and compared by bytes,
    # so the pass is linear in the line.
    #
    # @example
    #   RakeShellRedaction.redact('PGPASSWORD=s3cret pg_dump widgets')
    #   # => "PGPASSWORD=[REDACTED] pg_dump widgets"
    module RakeShellRedaction
      REDACTED = ConfigSourceGuard::REDACTED

      # One piece of a shell argument: a quoted run (its closing quote may be
      # missing) or an unquoted run.
      ARGUMENT_PART = /"(?:[^"\\]|\\.)*+"?|'[^']*+'?|`[^`]*+`?|[^\s"'`]++/m
      SPACE = /\s++/
      WHITESPACE = /\s/

      # A variable, flag or header name.
      NAME = /\A[A-Za-z_][\w-]*+\z/

      # A value that reads as a port or a port mapping (`2222`, `8080:80`).
      PORT = /\A[\d.:]++\z/

      # Authorization schemes whose next word is the credential.
      SCHEMES = %w[bearer basic].freeze

      USER_FLAGS = %w[-u --user].freeze

      # Short flags that take a password, by program.
      PASSWORD_FLAGS = {
        'mysql' => '-p', 'mysqldump' => '-p', 'mysqladmin' => '-p', 'mariadb' => '-p', 'mariadb-dump' => '-p',
        'sshpass' => '-p', 'docker' => '-p', 'podman' => '-p', 'redis-cli' => '-a'
      }.freeze

      # Words that run the next word as the program.
      WRAPPERS = %w[env sudo exec command time nice nohup].freeze

      # Arguments that end one command and start the next.
      COMMAND_SEPARATORS = %w[; && || | &].freeze

      # `"`, `'` and a backtick: quotes that may wrap a word.
      QUOTE_BYTES = [34, 39, 96].freeze

      REFERENCE_PREFIXES = ['$', '#{'].freeze

      # What the next argument must be checked for, and which program the
      # current command runs.
      State = Struct.new(:pending, :program, :expect_program)

      module_function

      # @param command [String] one command line
      # @return [String] the line with credential values replaced by {REDACTED}
      def redact(command)
        redact_arguments(ConfigSourceGuard.redact(command), nested: false)
      end

      def redact_arguments(text, nested:)
        scanner = StringScanner.new(text)
        state = State.new(nil, nil, true)
        output = +''
        until scanner.eos?
          space = scanner.scan(SPACE)
          next output << space if space

          output << redact_argument(next_argument(scanner), state, nested)
        end
        output
      end

      def next_argument(scanner)
        argument = +''
        while (part = scanner.scan(ARGUMENT_PART))
          argument << part
        end
        argument.empty? ? scanner.getch : argument
      end

      def redact_argument(argument, state, nested)
        if state.pending
          redacted = pending_redaction(argument, state.pending)
          state.pending = nil
          return redacted if redacted
        end
        track_program(argument, state)

        lead, core, trail = split_quotes(argument)
        return "#{lead}#{redact_quoted(core, nested)}#{trail}" if lead.bytesize.positive? && quoted_text?(core)

        redacted, state.pending = redact_core(core, state.program)
        redacted ? "#{lead}#{redacted}#{trail}" : argument
      end

      def pending_redaction(argument, pending)
        case pending
        when :userinfo then redacted_userinfo(argument)
        when :password_flag then redacted_password(argument)
        else redacted_value(argument, pending)
        end
      end

      # The program a command runs: its first word that is not an
      # assignment or a wrapper.
      def track_program(argument, state)
        return state.expect_program = true if COMMAND_SEPARATORS.include?(argument)
        return unless state.expect_program
        return if assignment_name(argument)

        word = File.basename(argument)
        state.program = word
        state.expect_program = WRAPPERS.include?(word)
      end

      # A quoted argument holding spaces or quotes: its words are arguments
      # of their own (a header), and a quoted literal inside it is Ruby-like
      # source to the guard (a JSON body).
      def quoted_text?(core)
        core.match?(WHITESPACE) || core.include?('"') || core.include?("'")
      end

      def redact_quoted(core, nested)
        text = core.include?('"') || core.include?("'") ? ConfigSourceGuard.redact_assigned_literals(core) : core
        nested || !text.match?(WHITESPACE) ? text : redact_arguments(text, nested: true)
      end

      # @return [Array(String, Symbol, nil)] the redacted core (nil when
      #   unchanged) and what the next argument must be checked for
      def redact_core(core, program)
        return [nil, :credential] if SCHEMES.include?(core.downcase)
        return [nil, :userinfo] if USER_FLAGS.include?(core)

        password_flag = PASSWORD_FLAGS[program]
        return redact_password_flag(core, password_flag) if password_flag && core.start_with?(password_flag)
        return [redact_query(core), nil] if core.include?('?')
        return redact_flag(core) if core.start_with?('-')

        assignment = redact_assignment(core)
        return [assignment, nil] if assignment || assignment_name(core)

        redact_header(core)
      end

      def redact_password_flag(core, flag)
        return [nil, :password_flag] if core == flag

        value = redacted_password(core.byteslice(flag.bytesize, core.bytesize - flag.bytesize))
        [value && "#{flag}#{value}", nil]
      end

      def redact_query(core)
        address, _, query = core.partition('?')
        parameters = query.split('&', -1)
        redacted = parameters.map { |parameter| redact_assignment(parameter) || parameter }
        "#{address}?#{redacted.join('&')}" unless redacted == parameters
      end

      # `Name:` arms the next argument; `Name:value` redacts its own value.
      def redact_header(core)
        name, separator, value = core.partition(':')
        return [nil, nil] if separator.empty? || value.start_with?('//') || !name.match?(NAME)

        mode = arming(name)
        return [nil, nil] unless mode
        return [nil, mode] if value.empty?
        return [nil, :credential] if SCHEMES.include?(value.downcase)

        redacted = redacted_value(value, mode)
        [redacted && "#{name}:#{redacted}", nil]
      end

      def redact_flag(core)
        if core.start_with?('-u') && !core.start_with?('--') && core.include?(':')
          return ["-u#{redacted_userinfo(core.delete_prefix('-u')) || core.delete_prefix('-u')}", nil]
        end

        if core.start_with?('--user=')
          userinfo = core.delete_prefix('--user=')
          return ["--user=#{redacted_userinfo(userinfo) || userinfo}", nil]
        end

        dashes = core.start_with?('--') ? 2 : 1
        flag = core.byteslice(dashes, core.bytesize - dashes)
        return [nil, flag.match?(NAME) ? arming(flag) : nil] unless flag.include?('=')

        redacted = redact_assignment(flag)
        [redacted && "#{core.byteslice(0, dashes)}#{redacted}", nil]
      end

      # `name=value` with a credential- or sensitive-named name.
      #
      # @return [String, nil] the redacted assignment, or nil when unchanged
      def redact_assignment(text)
        name = assignment_name(text)
        return nil unless name

        mode = arming(name)
        value = text.byteslice(name.bytesize + 1, text.bytesize - name.bytesize - 1)
        redacted = mode && redacted_value(value, mode)
        "#{name}=#{redacted}" if redacted
      end

      # @return [String, nil] the name of a `NAME=value` argument
      def assignment_name(text)
        name, separator, = text.partition('=')
        name if !separator.empty? && name.match?(NAME)
      end

      # @return [String, nil] +value+ with its literal withheld, or nil when it is kept
      def redacted_value(value, mode)
        lead, core, trail = split_quotes(value)
        return nil if core.empty? || REFERENCE_PREFIXES.any? { |prefix| core.start_with?(prefix) }
        return nil if mode == :sensitive && !ConfigSourceGuard.opaque?(core)

        "#{lead}#{REDACTED}#{trail}"
      end

      def redacted_password(value)
        _, core, = split_quotes(value)
        return nil if core.match?(PORT) || core.start_with?('-')

        redacted_value(value, :credential)
      end

      def redacted_userinfo(word)
        user, separator, password = word.partition(':')
        return nil if separator.empty? || password.empty?

        _, _, trail = split_quotes(password)
        "#{user}:#{REDACTED}#{trail}"
      end

      # @return [Symbol, nil] +:credential+, +:sensitive+ or nil
      def arming(name)
        ConfigSourceGuard.arming(name.tr('-', '_')) || nil
      end

      # @return [Array(String, String, String)] leading quotes, the word, trailing quotes
      def split_quotes(word)
        size = word.bytesize
        start = 0
        start += 1 while start < size && QUOTE_BYTES.include?(word.getbyte(start))
        stop = size
        stop -= 1 while stop > start && QUOTE_BYTES.include?(word.getbyte(stop - 1))
        [word.byteslice(0, start), word.byteslice(start, stop - start), word.byteslice(stop, size - stop)]
      end

      private_class_method :redact_arguments, :next_argument, :redact_argument, :pending_redaction,
                           :track_program, :quoted_text?, :redact_quoted, :redact_core, :redact_password_flag,
                           :redact_query, :redact_header, :redact_flag, :redact_assignment, :assignment_name,
                           :redacted_value, :redacted_password, :redacted_userinfo, :arming, :split_quotes
    end
  end
end
