# frozen_string_literal: true

module Woods
  module Extractors
    # Works out which subdomain a test file's requests are made on, when the
    # file says so with a literal.
    #
    # Recognized: `host! "shop.example.test"`, Capybara app/default hosts,
    # a `subdomain:` option, and a call to one of the configured helper names
    # (`config.test_subdomain_helpers`) with a literal argument. A file may
    # name several subdomains; none, or an interpolated value anywhere, means
    # unknown.
    #
    # @example
    #   TestRequestHost.subdomain(%(before { host! "shop.example.test" }))  # => "shop"
    #   TestRequestHost.subdomains(%(host! "shop.example.test"\nhost! "app.example.test"))  # => ["shop", "app"]
    #   TestRequestHost.subdomain(%(visit "/settings"))                     # => nil
    #
    module TestRequestHost
      # Must equal `Woods::Configuration#test_subdomain_helpers`' default.
      DEFAULT_HELPERS = %w[with_subdomain use_subdomain using_subdomain set_subdomain switch_to_subdomain
                           on_subdomain].freeze

      LITERAL = /(?:"([^"\n]*)"|'([^'\n]*)'|:(\w+))/
      HOST = /\bhost![ \t(]+(?:"([^"\n]*)"|'([^'\n]*)')/
      HOST_CALL = /\bhost![ \t(]/
      # A whole string literal shaped like a host name, read in a file that
      # calls host!, since host! may read it from data.
      HOST_STRING = /(?:"([a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+)"|'([a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+)')/i
      FILE_EXTENSION = /\.(?:rb|erb|json|csv|txt|png|jpe?g|gif|svg|webp|pdf|ya?ml|xml|html?|zip|gz|js|css|md|log)\z/i
      CAPYBARA_SPEC = /
        (?<![\w:@$])visit[ \t(]|\.visit[ \t(]
        |(?:\btype:|:type[ \t]*=>)[ \t]*:(?:feature|system)\b
        |\brequire(?:_relative)?[ \t(]+["'][^"'\n]*acceptance_helper["']
      /x
      APP_HOST = %r{\b(?:app_host|default_host)[ \t]*=[ \t]*["']https?://([^"'/\n:]+)}
      CAPYBARA_HOST = %r{\bCapybara\.(app_host|default_host)[ \t]*=[ \t]*["']https?://([^"'/\n:]+)}
      OPTION = /(?:\bsubdomain:|:subdomain[ \t]*=>)[ \t]*#{LITERAL}/

      module_function

      # @param source [String] Ruby source of a test file
      # @return [String, nil] the one subdomain the file names ("" for a host
      #   without one), or nil when it is unknown
      def subdomain(source)
        found = subdomains(source)
        found&.one? ? found.first : nil
      end

      # @param source [String] Ruby source of a test file
      # @return [Array<String>, nil] every subdomain the file names, or nil
      #   when it names none or interpolates one
      def subdomains(source)
        return nil unless hosts_literal?(source)

        found = literal_subdomains(source)
        found.empty? ? nil : found
      end

      # @param source [String] Ruby source of a test file
      # @return [Array<String>] the subdomains the file names with a literal,
      #   even beside an interpolated one
      def literal_subdomains(source)
        (hosts(source).map { |host| subdomain_of(host) } + named(source)).reject { |value| value.include?('#{') }.uniq
      end

      # Does the file supply its own host hints, even when ambiguous?
      #
      # @param source [String] Ruby source of a test file
      # @return [Boolean]
      def specifies_host?(source)
        (hosts(source) + named(source)).any? || source.match?(HOST_CALL)
      end

      # Does the Capybara default host apply? Only to feature and system
      # specs: a file that visits, is tagged `type: :feature` or `:system`,
      # or requires the acceptance helper. A request spec never gets it.
      #
      # @param source [String] Ruby source of a test file
      # @return [Boolean]
      def capybara_spec?(source)
        source.match?(CAPYBARA_SPEC)
      end

      # Resolve the Capybara default from the catalog's support source.
      # app_host takes precedence over default_host. A literal host wins and
      # a configured helper's literal argument never cancels it; without a
      # literal, a lone helper literal is the default. An interpolated host
      # counts for nothing. Competing defaults remain unknown. No support code
      # is executed.
      #
      # @param source [String] Ruby source of the test support files
      # @return [String, nil]
      def capybara_subdomain(source)
        literals, helper_literals = capybara_hosts(source)
        found = literals.empty? ? helper_literals : literals
        found.one? ? found.first : nil
      end

      # Every subdomain the support source can put the Capybara host on: its
      # literal hosts, widened by configured helpers' literal arguments.
      #
      # @param source [String] Ruby source of the test support files
      # @return [Array<String>]
      def capybara_subdomains(source)
        capybara_hosts(source).inject(:|)
      end

      # @return [Array(Array<String>, Array<String>)] literal host subdomains
      #   and configured helpers' literal arguments
      def capybara_hosts(source)
        source = source.each_line.grep_v(/\A[ \t]*#/).join
        configured = source.scan(CAPYBARA_HOST).group_by(&:first)
        hosts = (configured['app_host'] || configured['default_host'] || []).map(&:last)
        literals = hosts.map { |host| subdomain_of(host) }.reject { |value| value.include?('#{') }.uniq
        helper_literals = helper_pattern ? source.scan(helper_pattern).map { |captures| captures.compact.first } : []
        [literals, helper_literals.uniq]
      end

      # @return [Array<String>] the configured helper names
      def helpers
        configured = Woods.configuration if Woods.respond_to?(:configuration)
        configured.respond_to?(:test_subdomain_helpers) ? configured.test_subdomain_helpers : DEFAULT_HELPERS
      end

      def hosts(source)
        found = (source.scan(HOST) + source.scan(APP_HOST)).map { |captures| captures.compact.first }
        found + host_strings(source)
      end

      # Every literal host string counts as a named host once the file calls
      # host!, whether host! takes it directly or reads it from data.
      def host_strings(source)
        return [] unless source.match?(HOST_CALL)

        source.scan(HOST_STRING).map { |captures| captures.compact.first }
              .select { |host| host.split('.').last.match?(/\A[a-z]+\z/i) && !host.match?(FILE_EXTENSION) }
      end

      # An interpolated host or subdomain anywhere makes the file's subdomain
      # depend on runtime data, whatever literals sit beside it.
      def hosts_literal?(source)
        (hosts(source) + named(source)).none? { |value| value.include?('#{') }
      end

      def named(source)
        values = source.scan(OPTION)
        values += source.scan(helper_pattern) if helper_pattern
        values.map { |captures| captures.compact.first }
      end

      def helper_pattern
        names = helpers
        return nil if names.empty?

        @helper_patterns ||= {}
        @helper_patterns[names] ||= /(?<![\w.:@$])(?:#{Regexp.union(names)})[ \t(]+#{LITERAL}/
      end

      # Everything left of the registrable domain: `a.b.example.test` is "a.b".
      def subdomain_of(host)
        return host if host.include?('#{')

        labels = host.split('.')
        labels.size > tld_length + 1 ? labels[0...-(tld_length + 1)].join('.') : ''
      end

      def tld_length
        return 1 unless defined?(ActionDispatch::Http::URL) && ActionDispatch::Http::URL.respond_to?(:tld_length)

        ActionDispatch::Http::URL.tld_length.to_i
      end
    end
  end
end
