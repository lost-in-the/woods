# frozen_string_literal: true

require_relative '../console/credential_scanner'

module Woods
  module Extractors
    # Guards for configuration source that is published verbatim: boot files,
    # seeds, deploy scripts, a Gemfile, route files.
    #
    # These files are where a hand-written credential tends to live (a gem
    # source URL with a token, a deploy password, a seeded admin key), so the
    # text is passed through the Console credential-shape patterns before it
    # reaches the index. The rest of the source is untouched.
    module ConfigSourceGuard
      REDACTED = Console::CredentialScanner::REDACTED

      # The scanner's shape patterns. Private key blocks are handled by
      # {.redact_private_keys}, a line pass, in place of the scanner's lazy
      # multi-line pattern.
      PATTERNS = Console::CredentialScanner::PATTERNS.except(:pem_private_key_block).values.freeze

      # `scheme://user:password@` in any scheme.
      URL_USERINFO = %r{(://)[^\s/:@'"]++:[^\s/@'"]++@}

      PRIVATE_KEY_BEGIN = 'PRIVATE KEY-----'
      PRIVATE_KEY_HEADER = '-----BEGIN'
      PRIVATE_KEY_FOOTER = '-----END'

      module_function

      # @param source [String] file text
      # @return [String] the text with credential-shaped substrings replaced
      def redact(source)
        text = PATTERNS.reduce(source) { |current, pattern| current.gsub(pattern, REDACTED) }
        text = text.gsub(URL_USERINFO) { "#{Regexp.last_match(1)}#{REDACTED}@" }
        text.include?(PRIVATE_KEY_BEGIN) ? redact_private_keys(text) : text
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
