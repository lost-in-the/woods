# frozen_string_literal: true

require_relative '../console/credential_scanner'
require_relative 'config_source_guard'

module Woods
  module Extractors
    # Best-effort credential redaction for published documentation source.
    #
    # Applies the shape patterns of {Woods::Console::CredentialScanner} line by
    # line, so a published `doc` unit carries `[REDACTED]` where a Console
    # response would, then the URL-userinfo pass configuration source gets
    # ({ConfigSourceGuard.redact_url_userinfo}): `https://token@host` keeps
    # its scheme and host. Three things differ from scanning the document
    # whole:
    #
    # * PEM private key blocks are found by a line state machine and every line
    #   of the block is replaced, so line numbers survive.
    # * A line over {MAX_SCAN_BYTES} is scanned word by word, and a single word
    #   over the cap is replaced outright. Scan time stays bounded per word.
    # * The value of a front matter key that names a credential is replaced
    #   whatever its shape.
    #
    # It recognizes shapes, not secrets: a credential in a form the scanner
    # does not know is published as written.
    #
    # @example
    #   text, counts = DocRedaction.new.call("key: sk_test_...\n")
    #   counts # => { "stripe_secret_key" => 1 }
    class DocRedaction
      REDACTED = Console::CredentialScanner::REDACTED
      # One scanner call never sees more than this. Some scanner shapes cost
      # quadratic time in a run of near-matches on Ruby before 3.2, so the cap
      # is what keeps a hostile document linear: about a second per megabyte
      # at worst there. A real credential longer than the cap is replaced as
      # an oversize token.
      MAX_SCAN_BYTES = 1024
      # Every scanner shape is longer than this and holds no whitespace.
      MIN_CREDENTIAL_BYTES = 12
      # `auth` alone, so `author` stays a plain key.
      CREDENTIAL_KEY = /pass(?:word|wd|phrase)|secret|token|api[_.-]?key|private[_.-]?key|credential|
                        auth(?:orization|entication)?(?![a-z])/ix
      WHITESPACE_RUNS = /(\s+)/
      private_constant :CREDENTIAL_KEY, :WHITESPACE_RUNS

      # @param key [String] front matter key
      # @return [Boolean] whether the key names a credential
      def self.credential_key?(key)
        CREDENTIAL_KEY.match?(key.to_s)
      end

      # @param scanner [Woods::Console::CredentialScanner]
      def initialize(scanner: Console::CredentialScanner.new)
        @scanner = scanner
      end

      # @param source [String] Markdown text
      # @param front_matter [Array<Hash>] `{ key:, value:, line: }` from {Woods::Markdown::LineScan}
      # @param front_matter_lines [Range, nil] 1-based lines of the front matter block
      # @return [Array(String, Hash{String => Integer})] redacted text and a sorted per-shape count
      def call(source, front_matter: [], front_matter_lines: nil)
        @counts = Hash.new(0)
        @in_key_block = false
        secret_lines = front_matter_lines ? credential_lines(front_matter) : {}
        lines = source.split("\n", -1).each_with_index.map do |line, index|
          redact_line(line, secret_lines[index + 1])
        end
        [lines.join("\n"), @counts.sort.to_h]
      end

      private

      def credential_lines(front_matter)
        front_matter.each_with_object({}) do |entry, lines|
          lines[entry[:line]] = entry[:key] if self.class.credential_key?(entry[:key]) && !entry[:value].empty?
        end
      end

      def redact_line(line, secret_key)
        return redact_key_block_line(line) if @in_key_block || key_block_start?(line)
        return redact_front_matter_value(line, secret_key) if secret_key
        return line unless line.split.any? { |word| word.bytesize >= MIN_CREDENTIAL_BYTES }
        return scan(line) if line.bytesize <= MAX_SCAN_BYTES

        line.split(WHITESPACE_RUNS).map { |part| scan_word(part) }.join
      end

      def key_block_start?(line)
        return false unless line.include?('-----BEGIN ') && line.include?('PRIVATE KEY-----')

        @counts['pem_private_key_block'] += 1
        true
      end

      def redact_key_block_line(line)
        @in_key_block = !(line.include?('-----END ') && line.include?('PRIVATE KEY-----'))
        line.end_with?("\r") ? "#{REDACTED}\r" : REDACTED
      end

      def redact_front_matter_value(line, key)
        @counts['front_matter_value'] += 1
        "#{key}: #{REDACTED}#{"\r" if line.end_with?("\r")}"
      end

      def scan_word(word)
        return word if word.bytesize < MIN_CREDENTIAL_BYTES
        return scan(word) if word.bytesize <= MAX_SCAN_BYTES

        @counts['oversize_token'] += 1
        REDACTED
      end

      # The scanner's shapes, then the URL-userinfo pass configuration
      # source gets, so `https://token@host` is withheld in both.
      def scan(text)
        scanned, counts = @scanner.scan(text)
        counts.each { |name, count| @counts[name.to_s] += count }
        return scanned unless scanned.include?('://')

        ConfigSourceGuard.redact_url_userinfo(scanned) { @counts['url_userinfo'] += 1 }
      end
    end
  end
end
