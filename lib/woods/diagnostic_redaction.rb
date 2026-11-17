# frozen_string_literal: true

require 'set'
require 'uri'

module Woods
  # Removes database connection details from a diagnostic before it reaches
  # stderr, a log, an MCP response, +woods_status+ or a task record.
  #
  # A database adapter's own exception messages can carry the host, the user,
  # the database name and sometimes the password or the whole conninfo, and a
  # Woods message that quotes one carries the same. Every site that turns such
  # an error into text goes through {.redact} or {.describe}.
  #
  # Two layers:
  #
  # - forms: a database URL (any other URL keeps all but its
  #   +user:password@+ part), +key=value+ conninfo pairs, Ruby
  #   +inspect+ output of a configuration hash, the quoted host, user,
  #   database and role names in PostgreSQL and MySQL error text, and the
  #   +hostname:+ and +username:+ Active Record's connection errors name;
  # - values: the password, user:password pair and URL {.register}ed from a
  #   connection Woods opened, wherever they appear. Host, user and database
  #   names are left to the forms: a database named +woods+ must not turn
  #   +woods.json+ into +[REDACTED].json+.
  module DiagnosticRedaction # rubocop:disable Metrics/ModuleLength -- one redaction policy for every diagnostic site
    # @return [String] what a removed value is replaced with
    MARK = '[REDACTED]'

    # Keys whose value names or opens a database.
    CONNECTION_KEYS = %w[
      password passwd pwd sslpassword passfile sslkey user username host hostaddr socket dbname database service url
    ].freeze

    PASSWORD_KEYS = %w[password passwd pwd sslpassword].freeze
    private_constant :PASSWORD_KEYS

    KEY_PATTERN = CONNECTION_KEYS.map { |key| Regexp.escape(key) }.join('|')
    private_constant :KEY_PATTERN

    QUOTED = %q{"(?:[^"\\\\]|\\\\.)*"|'(?:[^'\\\\]|\\\\.)*'}
    private_constant :QUOTED

    # Phrases a database client puts before a quoted host, socket, user or
    # database name.
    QUOTING_PHRASES = 'server at|server on socket|server on|through socket|for user|user|database|role|' \
                      'host name|network address|socket path|host|db'
    private_constant :QUOTING_PHRASES

    # Encodings whose text is read as UTF-8, as error messages usually are.
    UTF8_READ = [Encoding::BINARY, Encoding::US_ASCII].freeze
    private_constant :UTF8_READ

    FORMS = [
      # a database URL, whole: postgres://user:password@host:5432/name
      [%r{\b((?:postgres(?:ql)?|mysql2?|trilogy|sqlserver|oracle-enhanced)://)[^\s'"]+}i, "\\1#{MARK}"],
      # any other URL's user:password@, through the last @ before the host
      [%r{\b([a-z][a-z0-9+.-]*://)[^\s/?#'"]*@}i, "\\1#{MARK}@"],
      # {:password=>"x"}, {password: "x"}, {"password" => "x"}
      [/(["':]?\b(?:#{KEY_PATTERN})["']?\s*(?:=>|:)\s*)(?:#{QUOTED}|:\w+)/i, "\\1\"#{MARK}\""],
      # Active Record: "with your hostname: h." and "username: u."; the value
      # runs to whitespace, less one closing [.,;]
      [/\b((?:hostname|username|host|user|database|password)\s*:\s+)(?!"?#{Regexp.escape(MARK)})
        \S+?(?=[.,;]?(?:\s|$))/xi, "\\1#{MARK}"],
      # conninfo: password=x host='y'; an unquoted value runs to whitespace,
      # a backslash escaping the next character, as libpq reads it
      [/\b((?:#{KEY_PATTERN})\s*=\s*)(?:#{QUOTED}|(?:\\.|[^\s\\])+)/i, "\\1#{MARK}"],
      # PostgreSQL, MySQL and MariaDB: server at "h" (10.0.0.1), for user "u",
      # database 'd', 'u'@'h', host name "h", server on 'h', through socket 's'
      [/\b((?:#{QUOTING_PHRASES})\s+)(?:#{QUOTED})(@(?:#{QUOTED}))?/i, "\\1\"#{MARK}\""],
      [/(server at "#{Regexp.escape(MARK)}"\s+)\([^)]*\)/, "\\1(#{MARK})"]
    ].freeze
    private_constant :FORMS

    @values = Set.new
    @lock = Mutex.new

    class << self
      # Registered values go first, whole, so a form cannot split one; then
      # the forms.
      #
      # @param text [#to_s, nil] in any encoding, valid or not
      # @return [String] +text+ as valid UTF-8, without connection details
      def redact(text)
        result = remove_registered(utf8(text))
        FORMS.each { |pattern, replacement| result = result.gsub(pattern, replacement) }
        result
      end

      # @param error [Exception]
      # @return [String] +"Class: message"+, redacted
      def describe(error)
        "#{error.class}: #{redact(error.message)}"
      end

      # A structured details hash, redacted value by value: a password-like
      # key's value is removed and every string goes through {.redact}. Keys
      # keep their meaning, so a +host:+ that names the host application's
      # provider is not mistaken for a database host.
      #
      # @param details [Hash]
      # @return [Hash]
      def redact_details(details)
        details.to_h do |key, value|
          next [key, MARK] if PASSWORD_KEYS.include?(key.to_s.downcase)

          [key, redact_value(value)]
        end
      end

      # Remember the connection details of a connection Woods opens, so later
      # diagnostics drop them wherever they appear.
      #
      # @param source [String, Hash, Object] a database URL, a configuration
      #   hash, or a connection or pool whose database configuration is read
      # @return [void]
      def register(source)
        found = connection_values(source)
        @lock.synchronize { @values.merge(found) } unless found.empty?
      rescue StandardError
        nil
      end

      # Forget every registered value (specs; a process that closed its
      # connections).
      #
      # @return [void]
      def clear!
        @lock.synchronize { @values.clear }
      end

      private

      def values
        @lock.synchronize { @values.to_a }
      end

      def redact_value(value)
        case value
        when Hash then redact_details(value)
        when Array then value.map { |item| redact_value(item) }
        when String then redact(value)
        else value
        end
      end

      # Any text as valid UTF-8; bytes that are not valid UTF-8 become U+FFFD.
      def utf8(text)
        string = text.to_s
        return string.dup.force_encoding(Encoding::UTF_8).scrub if UTF8_READ.include?(string.encoding)

        string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      end

      # Every character inside an occurrence of any registered value is
      # removed, so values that overlap or contain one another leave no part.
      def remove_registered(text)
        spans = values.flat_map do |value|
          text.enum_for(:scan, value_pattern(value)).map { Regexp.last_match.offset(0) }
        end
        merge_spans(spans).reverse_each.with_object(text.dup) { |(from, to), result| result[from...to] = MARK }
      end

      def merge_spans(spans)
        spans.sort.each_with_object([]) do |(from, to), merged|
          next merged << [from, to] if merged.empty? || from > merged.last[1]

          merged.last[1] = [merged.last[1], to].max
        end
      end

      def value_pattern(value)
        /(?<![A-Za-z0-9_])#{Regexp.escape(value)}(?![A-Za-z0-9_])/
      end

      def connection_values(source)
        case source
        when String then url_values(utf8(source))
        when Hash then hash_values(source)
        else hash_values(configuration_hash(source) || {})
        end.compact.map { |value| utf8(value) }.reject(&:empty?).uniq
      end

      # The password percent-decoded as Active Record reads it, +plus+ kept,
      # and form-decoded as well.
      def url_values(url)
        uri = URI.parse(url)
        password = uri.password
        return [url] unless password

        [url, uri.userinfo, password, URI::DEFAULT_PARSER.unescape(password), URI.decode_www_form_component(password)]
      rescue URI::Error
        [url]
      end

      def hash_values(config)
        config = config.transform_keys(&:to_s)
        config['url'].is_a?(String) ? [config['password'], *url_values(utf8(config['url']))] : [config['password']]
      end

      def configuration_hash(source)
        pool = source.respond_to?(:pool) ? source.pool : source
        db_config = pool.respond_to?(:db_config) ? pool.db_config : nil
        return db_config.configuration_hash if db_config.respond_to?(:configuration_hash)

        spec = pool.respond_to?(:spec) ? pool.spec : nil
        spec.config if spec.respond_to?(:config)
      end
    end
  end
end
