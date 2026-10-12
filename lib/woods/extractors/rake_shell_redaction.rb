# frozen_string_literal: true

require_relative 'config_source_guard'

module Woods
  module Extractors
    # Redacts credentials in a shell command line before it is published as
    # `metadata.shell_commands`.
    #
    # {ConfigSourceGuard.redact} runs first: known credential shapes, URL
    # userinfo and private keys. Then one pass over the line's
    # whitespace-separated words withholds what a command line carries that
    # Ruby source does not:
    #
    # * `NAME=value`, `--name=value` and `--name value`, when the name is
    #   credential-named (any value) or sensitive-named (a value that reads
    #   as a generated token). A `$VAR` or `#{...}` value is a reference and
    #   is kept.
    # * The word after `Bearer` or `Basic`, and after a credential-named
    #   header such as `X-Api-Key:`.
    # * The password half of `-u user:password` and `--user=user:password`.
    # * Credential-named query parameters (`?token=...`).
    #
    # Words are compared byte by byte and split on literal characters, so the
    # pass is linear in the line.
    #
    # @example
    #   RakeShellRedaction.redact('PGPASSWORD=s3cret pg_dump widgets')
    #   # => "PGPASSWORD=[REDACTED] pg_dump widgets"
    module RakeShellRedaction
      REDACTED = ConfigSourceGuard::REDACTED

      WORDS = /\S++|\s++/

      # A variable, flag or header name.
      NAME = /\A[A-Za-z_][\w-]*+\z/

      # Authorization schemes whose next word is the credential.
      SCHEMES = %w[bearer basic].freeze

      USER_FLAGS = %w[-u --user].freeze

      # `"`, `'` and a backtick: quotes that may wrap a word.
      QUOTE_BYTES = [34, 39, 96].freeze

      REFERENCE_PREFIXES = ['$', '#{'].freeze

      module_function

      # @param command [String] one command line
      # @return [String] the line with credential values replaced by {REDACTED}
      def redact(command)
        pending = nil
        ConfigSourceGuard.redact(command).scan(WORDS).map do |word|
          next word if word.start_with?(' ', "\t", "\n", "\r")

          redacted, pending = redact_word(word, pending)
          redacted
        end.join
      end

      # @return [Array(String, Symbol, nil)] the word as published, and what
      #   the next word must be checked for
      def redact_word(word, pending)
        if pending
          redacted = pending == :userinfo ? redacted_userinfo(word) : redacted_value(word, pending)
          return [redacted, nil] if redacted
        end

        lead, core, trail = split_quotes(word)
        return [word, :credential] if SCHEMES.include?(core.downcase)
        return [word, :userinfo] if USER_FLAGS.include?(core)

        redacted, pending = redact_core(core)
        [redacted ? "#{lead}#{redacted}#{trail}" : word, pending]
      end

      # @return [Array(String, Symbol, nil)] the redacted core (nil when
      #   unchanged) and the pending check for the next word
      def redact_core(core)
        return [redact_query(core), nil] if core.include?('?')
        return [nil, header_arming(core)] if core.end_with?(':')
        return redact_flag(core) if core.start_with?('-')

        [redact_assignment(core), nil]
      end

      def redact_query(core)
        address, _, query = core.partition('?')
        parameters = query.split('&', -1)
        redacted = parameters.map { |parameter| redact_assignment(parameter) || parameter }
        "#{address}?#{redacted.join('&')}" unless redacted == parameters
      end

      def header_arming(core)
        name = core.delete_suffix(':')
        name.match?(NAME) ? arming(name) : nil
      end

      def redact_flag(core)
        dashes = core.start_with?('--') ? 2 : 1
        flag = core.byteslice(dashes, core.bytesize - dashes)
        if flag.start_with?('user=') && dashes == 2
          return ["--user=#{redacted_userinfo(flag.delete_prefix('user=')) || flag.delete_prefix('user=')}", nil]
        end
        return [nil, nil] unless flag.match?(NAME) || flag.include?('=')
        return [nil, arming(flag)] unless flag.include?('=')

        redacted = redact_assignment(flag)
        [redacted && "#{core.byteslice(0, dashes)}#{redacted}", nil]
      end

      # `name=value` with a credential- or sensitive-named name.
      #
      # @return [String, nil] the redacted assignment, or nil when unchanged
      def redact_assignment(text)
        name, separator, value = text.partition('=')
        return nil if separator.empty? || !name.match?(NAME)

        mode = arming(name)
        redacted = mode && redacted_value(value, mode)
        "#{name}=#{redacted}" if redacted
      end

      # @return [String, nil] +value+ with its literal withheld, or nil when it is kept
      def redacted_value(value, mode)
        lead, core, trail = split_quotes(value)
        return nil if core.empty? || REFERENCE_PREFIXES.any? { |prefix| core.start_with?(prefix) }
        return nil if mode == :sensitive && !ConfigSourceGuard.opaque?(core)

        "#{lead}#{REDACTED}#{trail}"
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

      private_class_method :redact_word, :redact_core, :redact_query, :header_arming, :redact_flag,
                           :redact_assignment, :redacted_value, :redacted_userinfo, :arming, :split_quotes
    end
  end
end
