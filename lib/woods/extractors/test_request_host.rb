# frozen_string_literal: true

module Woods
  module Extractors
    # Works out which subdomain a test file's requests are made on, when the
    # file says so with a literal.
    #
    # Recognized: `host! "shop.example.test"`, `Capybara.app_host = "http://..."`,
    # a `subdomain:` option, and a call to one of the configured helper names
    # (`config.test_subdomain_helpers`) with a literal argument. The subdomain
    # is known only when the file names exactly one; several, none, or an
    # interpolated value all mean unknown.
    #
    # @example
    #   TestRequestHost.subdomain(%(before { host! "shop.example.test" }))  # => "shop"
    #   TestRequestHost.subdomain(%(visit "/settings"))                     # => nil
    #
    module TestRequestHost
      # Must equal `Woods::Configuration#test_subdomain_helpers`' default.
      DEFAULT_HELPERS = %w[with_subdomain use_subdomain using_subdomain set_subdomain switch_to_subdomain
                           on_subdomain].freeze

      LITERAL = /(?:"([^"\n]*)"|'([^'\n]*)'|:(\w+))/
      HOST = /\bhost![ \t(]+(?:"([^"\n]*)"|'([^'\n]*)')/
      APP_HOST = %r{\bapp_host[ \t]*=[ \t]*["']https?://([^"'/\n:]+)}
      OPTION = /(?:\bsubdomain:|:subdomain[ \t]*=>)[ \t]*#{LITERAL}/

      module_function

      # @param source [String] Ruby source of a test file
      # @return [String, nil] the one subdomain the file names ("" for a host
      #   without one), or nil when it is unknown
      def subdomain(source)
        found = hosts(source).map { |host| subdomain_of(host) } + named(source)
        found = found.reject { |value| value.include?('#{') }.uniq
        found.one? && hosts_literal?(source) ? found.first : nil
      end

      # @return [Array<String>] the configured helper names
      def helpers
        configured = Woods.configuration if Woods.respond_to?(:configuration)
        configured.respond_to?(:test_subdomain_helpers) ? configured.test_subdomain_helpers : DEFAULT_HELPERS
      end

      def hosts(source)
        (source.scan(HOST) + source.scan(APP_HOST)).map { |captures| captures.compact.first }
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
