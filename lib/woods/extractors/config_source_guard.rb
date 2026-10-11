# frozen_string_literal: true

require 'strscan'

module Woods
  module Extractors
    # Guards for configuration source that is published verbatim: boot files,
    # seeds, deploy scripts, a Gemfile, route files.
    #
    # These files are where a hand-written credential tends to live (a gem
    # source URL with a token, a deploy password, a seeded admin key), so the
    # text is redacted before it reaches the index. Four passes, each linear:
    #
    # 1. The Console credential scanner: known credential shapes, including
    #    URL-encoded and base64-wrapped ones.
    # 2. URL userinfo in any scheme, with or without a password separator.
    # 3. Private key blocks, header to footer.
    # 4. A string literal assigned to, or passed after, a credential-named key
    #    on the same line (`password: "..."`, `ENV["API_TOKEN"] = "..."`), or
    #    assigned to a sensitive-named key when the literal reads as a
    #    generated token (`pepper = "9f86d0..."`, `slack_webhook, "https://..."`).
    #
    # Redaction is best-effort by nature: a credential with no recognizable
    # shape, held under a name that says nothing, cannot be told from any
    # other string.
    module ConfigSourceGuard
      # Same marker as Woods::Console::CredentialScanner::REDACTED.
      REDACTED = '[REDACTED]'

      # `scheme://userinfo@`, where userinfo runs to the first `@` before any
      # path, space or quote. A token-only userinfo has no `:`.
      URL_USERINFO = %r{(://)[^\s/@'"]++@}

      PRIVATE_KEY_BEGIN = 'PRIVATE KEY-----'
      PRIVATE_KEY_HEADER = '-----BEGIN'
      PRIVATE_KEY_FOOTER = '-----END'

      # Name fragments that mark a key as credential-bearing: any literal
      # assigned to it is withheld.
      CREDENTIAL_NAME_FRAGMENTS = %w[
        password passwd passphrase secret token api_key apikey access_key private_key credential signature
      ].freeze

      # Name fragments that mark a key as sensitive: a literal assigned to it
      # is withheld when it reads as a generated token, so `key: '_session'`
      # and `to: 'webhooks#ledger'` stay readable. Covers every fragment the
      # YAML extractor withholds values under.
      SENSITIVE_NAME_FRAGMENTS = %w[
        pass pwd secret token key credential auth sign salt dsn encrypt cert private
        bearer cookie session hmac jwt license webhook otp pepper
      ].freeze

      # An unbroken run this long that mixes letters and digits reads as a
      # generated token, not a setting.
      OPAQUE_RUN = %r{[A-Za-z0-9+/=_-]{20,}+}

      # One token of a source line: a quoted literal, a word, a separator,
      # a whitespace run, or any single character.
      LINE_TOKEN = /"(?:[^"\\\n]|\\.)*+"|'(?:[^'\\\n]|\\.)*+'|[A-Za-z_]\w*+[?!]?+|=>|\|\|=?+|[ \t]++|./m
      SEPARATORS = ['=', '=>', ':', ',', '||', '||=', '('].freeze
      CLOSERS = [']', ')'].freeze

      module_function

      # @param source [String] file text
      # @return [String] the text with credential-bearing substrings replaced
      def redact(source)
        text = scanner.scan(source).first
        text = text.gsub(URL_USERINFO) { "#{Regexp.last_match(1)}#{REDACTED}@" }
        text = redact_private_keys(text) if text.include?(PRIVATE_KEY_BEGIN)
        redact_assigned_literals(text)
      end

      # Private key blocks are handled by {.redact_private_keys}, a line pass,
      # in place of the scanner's lazy multi-line pattern.
      #
      # @return [Console::CredentialScanner]
      def scanner
        @scanner ||= begin
          require_relative '../console/credential_scanner'
          Console::CredentialScanner.new(disabled_patterns: [:pem_private_key_block])
        end
      end

      # Replace each private key block, header to footer, with one marker
      # line. An unterminated block withholds the rest of the text.
      #
      # @param text [String]
      # @return [String]
      def redact_private_keys(text)
        inside = false
        text.each_line.filter_map do |line|
          if inside
            inside = false if line.include?(PRIVATE_KEY_FOOTER)
            next
          end
          next line unless line.include?(PRIVATE_KEY_HEADER) && line.include?(PRIVATE_KEY_BEGIN)

          inside = !line.include?(PRIVATE_KEY_FOOTER)
          "#{REDACTED}\n"
        end.join
      end

      # Replace a string literal that follows a credential-named or
      # sensitive-named key and a separator on the same line. Lines naming no
      # such key are untouched.
      #
      # @param text [String]
      # @return [String]
      def redact_assigned_literals(text)
        text.each_line.map { |line| candidate_line?(line) ? redact_line(line) : line }.join
      end

      def candidate_line?(line)
        (line.include?('"') || line.include?("'")) && arming(line)
      end

      # @return [Symbol, false] +:credential+, +:sensitive+, or false when the
      #   text names neither kind of key
      def arming(text)
        name = text.downcase
        return :credential if CREDENTIAL_NAME_FRAGMENTS.any? { |fragment| name.include?(fragment) }
        return :sensitive if SENSITIVE_NAME_FRAGMENTS.any? { |fragment| name.include?(fragment) }

        false
      end

      # @param text [String]
      # @return [Boolean] whether the text holds a run that reads as a generated token
      def opaque?(text)
        text.scan(OPAQUE_RUN).any? { |run| run.match?(/[A-Za-z]/) && run.match?(/\d/) }
      end

      # A key arms the pass; a separator after an armed key makes the next
      # literal a value. Any other word or symbol disarms it. A quote that
      # never closes ends the pass, so no later quote rescans the line: the
      # remainder is withheld when a value was expected, kept otherwise.
      def redact_line(line)
        output = +''
        armed = pending = false
        tokens = StringScanner.new(line)
        until tokens.eos?
          token = tokens.scan(LINE_TOKEN)
          return output << unterminated(token, tokens.rest, pending) if ['"', "'"].include?(token)

          output << (withhold?(token, pending) ? "#{token[0]}#{REDACTED}#{token[0]}" : token)
          armed, pending = next_state(token, armed, pending)
        end
        output
      end

      def withhold?(token, pending)
        return false unless pending && literal?(token)

        pending == :credential || opaque?(token)
      end

      def unterminated(quote, rest, pending)
        return "#{quote}#{rest}" unless pending

        "#{quote}#{REDACTED}#{"\n" if rest.end_with?("\n")}"
      end

      def next_state(token, armed, pending)
        return [armed, pending] if token.start_with?(' ', "\t") || CLOSERS.include?(token)
        return [armed, armed] if SEPARATORS.include?(token)
        return [false, false] if pending && literal?(token)
        return [arming(token), false] if literal?(token) || token.match?(/\A[A-Za-z_]/)

        [false, false]
      end

      def literal?(token)
        token.size >= 2 && token.start_with?('"', "'")
      end

      # Whether a path resolves to a regular file under the root. A symlink
      # that leaves the root is refused, so it cannot pull a foreign file into
      # the index under an application path.
      #
      # @param file_path [String] absolute path
      # @param root [String] application root
      # @return [Boolean]
      def inside_root?(file_path, root)
        return false unless File.file?(file_path)

        File.realpath(file_path).start_with?("#{File.realpath(root)}/")
      rescue SystemCallError
        false
      end
    end
  end
end
