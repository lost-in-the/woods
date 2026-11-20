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
      [/(server at (?:#{QUOTED})\s+)\([^)]*\)/, "\\1(#{MARK})"]
    ].freeze
    private_constant :FORMS

    @values = Set.new
    @lock = Mutex.new

    class << self # rubocop:disable Metrics/ClassLength -- one redaction policy for every diagnostic site
      # Registered values and forms are both found in the original text, so
      # neither can split or hide the other: a registered +password+ still
      # leaves +password=x+ recognisable. Their spans are removed together,
      # then the forms run once more over the result.
      #
      # @param text [#to_s, nil] in any encoding, valid or not
      # @return [String] +text+ as valid UTF-8, without connection details
      def redact(text)
        original = utf8(text)
        registered = registered_spans(original)
        result = remove_spans(original, form_spans(original, merge_spans(registered)) + registered)
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

      # What each form removes: the match after its kept first group, and the
      # text that replaces it. As when the forms run in turn, an earlier form
      # wins where two overlap, and the second pass applies the later one;
      # unless a +registered+ span hides the later one's first group.
      def form_spans(text, registered)
        hidden = []
        kept = FORMS.reduce([]) do |spans, (pattern, replacement)|
          fresh, overlapping = form_matches(text, pattern, replacement)
                               .partition { |_, from, to, _| !overlaps?(spans, from, to) }
          hidden.concat(overlapping.select { |start, from, _, _| overlaps?(registered, start, from) })
          (spans + fresh.map { |span| span.drop(1) }).sort
        end
        kept + hidden.map { |span| span.drop(1) }
      end

      def form_matches(text, pattern, replacement)
        tail = replacement.delete_prefix('\\1')
        text.enum_for(:scan, pattern).map do
          start, to = byte_offsets(Regexp.last_match, 0)
          [start, byte_offsets(Regexp.last_match, 1)[1], to, tail]
        end
      end

      # A character offset into UTF-8 text walks the text from its start,
      # so offsets are bytes; Ruby before 3.2 has no +byteoffset+.
      def byte_offsets(match, group)
        return match.byteoffset(group) if match.respond_to?(:byteoffset)

        offsets = match.offset(group)
        match.string.ascii_only? ? offsets : offsets.map { |at| match.string[0, at].bytesize }
      end

      # +spans+ are sorted and disjoint, so the first to end after +from+ is
      # the only one that can overlap.
      def overlaps?(spans, from, to)
        span = spans.bsearch { |_, span_to, _| span_to > from }
        !span.nil? && span[0] < to
      end

      def registered_spans(text)
        values.flat_map do |value|
          text.enum_for(:scan, value_pattern(value)).map { [*byte_offsets(Regexp.last_match, 0), MARK] }
        end
      end

      # Every character inside any span is removed, so spans that overlap or
      # contain one another leave no part. A merged span keeps the
      # replacement of the first span that covers all of it, else +MARK+.
      def remove_spans(text, spans)
        result = +''
        last = merge_spans(spans).reduce(0) do |at, (from, to, tail)|
          result << text.byteslice(at, from - at) << tail
          to
        end
        result << text.byteslice(last, text.bytesize - last)
      end

      def merge_spans(spans)
        ordered = spans.each_with_index.sort_by { |(from, to, _), index| [from, -to, index] }.map(&:first)
        ordered.each_with_object([]) do |(from, to, tail), merged|
          next merged << [from, to, tail] if merged.empty? || from > merged.last[1]
          next if to <= merged.last[1]

          merged.last[1] = to
          merged.last[2] = MARK
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

      # The userinfo password and every password-named query value, each
      # percent-decoded as Active Record reads it, +plus+ kept, and
      # form-decoded as well.
      def url_values(url)
        uri = URI.parse(url)
        decoded = [uri.password, *query_passwords(uri)].compact.flat_map do |password|
          [password, URI::DEFAULT_PARSER.unescape(password), URI.decode_www_form_component(password)]
        end
        [url, uri.password && uri.userinfo, *decoded]
      rescue URI::Error
        [url]
      end

      # Active Record splits the query on +&+ alone and the last repeat wins;
      # it is read split on +;+ as well and every repeat kept, to remove too
      # much rather than too little.
      def query_passwords(uri)
        pairs = (uri.opaque ? uri.opaque.partition('?').last : uri.query.to_s).split('&')
        (pairs + pairs.flat_map { |pair| pair.split(';') }).uniq.filter_map do |pair|
          key, value = pair.split('=', 2)
          value if PASSWORD_KEYS.include?(utf8(URI::DEFAULT_PARSER.unescape(key.to_s)).downcase)
        end
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
