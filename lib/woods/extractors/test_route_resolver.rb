# frozen_string_literal: true

require 'strscan'

require_relative 'route_extractor'
require_relative 'test_request_host'
require_relative 'test_support_catalog'
require_relative 'comment_blanking'

module Woods
  module Extractors
    # Resolves the navigation a feature, system or request test performs to
    # the route units it exercises.
    #
    # Recognized calls: `visit`, `get`, `post`, `put`, `patch`, `delete` and
    # `head`, given a route helper (`visit new_widget_path`) or a literal path
    # (`post "/widgets"`). A helper resolves through the live named-route map
    # to the route with the same path and the call's verb. A literal is matched
    # against each route's path pattern, in route order; an interpolation
    # stands for one segment value.
    #
    # Targets are the identifiers {RouteExtractor} emits, read from its own
    # output for the live route set, so an edge always names a route unit.
    # The result depends on the route table: the test mapping extractor is a
    # route consumer and re-runs when routes change.
    #
    # A literal can fit several routes when routes are constrained by
    # subdomain or by a callable. See {#decide}: the file's subdomains are used
    # when {TestRequestHost} can read them, each one deciding separately
    # (falling back to Capybara support
    # defaults only when the file supplies no host), a lone static route beats
    # parameter and glob routes, and a request that stays undecided is reported as
    # ambiguous with no edge. A path inside an assertion (`redirect_to`,
    # `have_current_path`) is reported as asserted, never as exercised.
    #
    # Not modeled, deliberately: segment constraints, the second and later
    # verbs of a multi-verb `match` route, and routes drawn inside mounted
    # engines.
    #
    # @example
    #   TestRouteResolver.new.exercised(%(visit "/widgets/#{widget.id}"\npost widgets_path))
    #   # => ["GET /widgets/:id", "POST /widgets"]
    #
    class TestRouteResolver
      # A navigation call and its target. `visit` may follow a receiver
      # (`page.visit`); the request verbs may not (`cache.get` is not a request).
      NAVIGATION = %r{
        (?:(?<![\w:@$.])(visit|get|post|put|patch|delete|head)|(?<=\.)(visit))
        [ \t(]+
        (?:(?:main_app\.)?([a-z_]\w*_(?:path|url))\b|"(/[^"\n]*)"|'(/[^'\n]*)')
      }x

      INTERPOLATION = /#\{[^}\n]*\}/
      # Longest literal worth matching; bounds the work of a path pattern.
      MAX_LITERAL_LENGTH = 512

      # A path inside an assertion is a claim about a response, not a request.
      ASSERTION = %r{
        (?<![\w.])(?:redirect_to|have_current_path|assert_redirected_to|assert_current_path)
        [ \t(]+
        (?:(?:main_app\.)?([a-z_]\w*_(?:path|url))\b|"(/[^"\n]*)"|'(/[^'\n]*)')
      }x

      Route = Struct.new(:identifier, :verb, :path, :name, :prefix, :subdomain, :callable, :static, :redirect,
                         keyword_init: true)

      # What one source does with the route table.
      #
      # +exercised+ and +asserted+ are sorted route identifiers. +ambiguous+
      # lists requests several routes could serve: `{ request:, candidates: }`.
      Analysis = Struct.new(:exercised, :asserted, :ambiguous, keyword_init: true)

      # @param support_catalog [TestSupportCatalog, nil] the extractor's support catalog
      def initialize(support_catalog: nil)
        @routes = load_routes
        @support_catalog = support_catalog
        @by_name = @routes.select(&:name).each_with_object({}) { |route, map| map[route.name] ||= route }
        @by_verb_and_path = @routes.each_with_object({}) { |route, map| map[[route.verb, route.path]] ||= route }
        @patterns = {}
        @literals = {}
      end

      # Route units the source exercises.
      #
      # @param source [String] Ruby source of a test file
      # @return [Array<String>] sorted, unique route identifiers
      def exercised(source)
        analyze(source).exercised
      end

      # Resolve every navigation call and asserted path in the source.
      #
      # @param source [String] Ruby source of a test file
      # @return [Analysis]
      def analyze(source)
        return Analysis.new(exercised: [], asserted: [], ambiguous: []) if @routes.empty?

        source = CommentBlanking.ruby(source)
        capybara = TestRequestHost.capybara_spec?(source)
        if TestRequestHost.specifies_host?(source)
          hosts = TestRequestHost.subdomains(source)
          reachable = TestRequestHost.literal_subdomains(source) | (capybara ? Array(default_hosts) : [])
        elsif capybara
          hosts = default_hosts
          reachable = support_hosts
        else
          hosts = nil
          reachable = []
        end
        requests = []
        asserted = []
        source.each_line do |line|
          line.scan(NAVIGATION) { |captures| requests.concat([resolve(hosts, reachable, *captures)].flatten(1)) }
          line.scan(ASSERTION) do |captures|
            asserted.concat([resolve(hosts, reachable, 'get', nil, *captures)].flatten(1))
          end
        end
        build_analysis(requests.compact, asserted.compact)
      end

      private

      def default_hosts
        return @default_hosts if defined?(@default_hosts)

        default = TestRequestHost.capybara_subdomain(support_source)
        @default_hosts = default && [default]
      end

      # Every subdomain the support default can be on: the reachable set of a
      # file that names no host.
      def support_hosts
        @support_hosts ||= TestRequestHost.capybara_subdomains(support_source)
      end

      def support_source
        return @support_source if @support_source

        entries = (@support_catalog || TestSupportCatalog.new).entries
        @support_source = entries.map { |entry| CommentBlanking.ruby(entry.source) }.join("\n")
      end

      def build_analysis(requests, asserted)
        ambiguous, exercised = requests.partition { |outcome| outcome.is_a?(Hash) }
        Analysis.new(exercised: exercised.uniq.sort, asserted: asserted.grep(String).uniq.sort,
                     ambiguous: ambiguous.uniq.sort_by { |entry| entry[:request] })
      end

      # @return [String, Array<String>, Hash, nil] route identifiers, an
      #   ambiguity record, or nil
      def resolve(hosts, reachable, verb, receiver_visit, helper, interpolated, literal)
        verb = (verb || receiver_visit) == 'visit' ? 'GET' : verb.upcase
        return helper_route(verb, helper) if helper

        path = normalize(interpolated || literal, interpolated: !interpolated.nil?)
        path && literal_route(verb, path, hosts, reachable)
      end

      # @return [String, nil] the route with the helper's path and this verb
      def helper_route(verb, helper)
        named = @by_name[helper.sub(/_(?:path|url)\z/, '')]
        return nil unless named

        (named.verb == verb ? named : @by_verb_and_path[[verb, named.path]])&.identifier
      end

      # Drop the query string, fragment and trailing slash, with each
      # interpolation standing for one segment value. A literal still holding
      # `#{` was cut short by a quote inside its interpolation. The length
      # bound comes first: it also bounds the interpolation scan.
      def normalize(path, interpolated:)
        return nil if path.length > MAX_LITERAL_LENGTH

        path = path.gsub(INTERPOLATION, '1') if interpolated
        return nil if path.include?('#{')

        path = path[/\A[^?#]*/].chomp('/')
        path.empty? ? '/' : path
      end

      def literal_route(verb, path, hosts, reachable)
        key = [verb, path, hosts, reachable]
        return @literals[key] if @literals.key?(key)

        candidates = @routes.select do |route|
          route.verb == verb && path.start_with?(route.prefix) && pattern_for(route.path).match?(path)
        end
        matches = candidates.select { |route| reachable?(route, reachable) }
        request = "#{verb} #{path}"
        @literals[key] = if hosts.nil? then decide_unknown(candidates, matches, request)
                         elsif hosts.size > 1 then decide_each(matches, hosts, request)
                         else decide(matches, hosts.first, request)
                         end
      end

      # With no known host, dropping unreachable redirects may shorten an
      # ambiguous list but must never turn it into a decision.
      #
      # @return [String, Hash, nil]
      def decide_unknown(candidates, matches, request)
        outcome = decide(matches, nil, request)
        return outcome unless outcome.is_a?(String)

        unfiltered = decide(candidates, nil, request)
        return outcome if unfiltered == outcome

        listed = unfiltered.is_a?(Hash) ? unfiltered[:candidates] : [unfiltered]
        { request: request, candidates: (listed | [outcome]).sort }
      end

      # A file naming several hosts makes its requests on each of them, so a
      # request exercises every route some named host decides. It is
      # ambiguous only when no named host decides it.
      #
      # @return [Array<String>, Hash, nil]
      def decide_each(matches, hosts, request)
        return nil if matches.empty?

        outcomes = hosts.map { |host| decide(matches, host, request) }
        decided = outcomes.grep(String).uniq
        return decided unless decided.empty?

        candidates = outcomes.grep(Hash).flat_map { |outcome| outcome[:candidates] }
        candidates = matches.map(&:identifier) if candidates.empty?
        { request: request, candidates: candidates.uniq.sort }
      end

      # Rails serves the first route, in table order, whose constraints the
      # request satisfies. Which constraints a test's request satisfies is
      # only partly knowable, so the winner is computed for every possibility
      # ("world"): each subdomain the request could be on, with callable
      # constraints passing and failing. One winner across all worlds is the
      # answer. Otherwise a single fully static winner beats parameter and
      # glob routes, and anything else is recorded as ambiguous.
      #
      # @return [String, Hash, nil]
      def decide(matches, subdomain, request)
        # For a known host, matching subdomain constraints are more specific
        # than an unconstrained fallback; retain route order within each group.
        if subdomain
          matches = matches.select { |route| satisfied?(route, subdomain, true) }
                           .partition(&:subdomain).flatten(1)
        end
        winners = worlds(matches, subdomain).filter_map do |host, callables_pass|
          matches.find { |route| satisfied?(route, host, callables_pass) }
        end.uniq
        return winners.first&.identifier if winners.size <= 1

        static = winners.select(&:static)
        return static.first.identifier if static.one?

        { request: request, candidates: winners.map(&:identifier).sort }
      end

      # @return [Array<Array>] `[subdomain world, callables pass]` pairs. A
      #   subdomain world is the known subdomain, or each constraint among the
      #   matches plus nil (a host that meets none of them).
      def worlds(matches, subdomain)
        hosts = subdomain ? [subdomain] : matches.map(&:subdomain).uniq | [nil]
        hosts.product(matches.any?(&:callable) ? [true, false] : [true])
      end

      # A redirect constrained to a subdomain that no named or default host
      # satisfies is never a candidate.
      def reachable?(route, reachable)
        !route.redirect || route.subdomain.nil? || reachable.any? { |host| satisfied?(route, host, true) }
      end

      def satisfied?(route, host, callables_pass)
        return false if route.callable && !callables_pass

        constraint = route.subdomain
        return true if constraint.nil? || constraint.equal?(host)
        return false unless host.is_a?(String)

        constraint.is_a?(Regexp) ? constraint.match?(host) : constraint == host
      end

      def pattern_for(route_path)
        @patterns[route_path] ||= compile(route_path)
      end

      # Turn a route path spec into an anchored pattern: `:name` is one
      # segment value, `*name` spans segments, `( )` is optional. A format
      # extension is accepted after any path.
      def compile(route_path)
        scanner = StringScanner.new(route_path == '/' ? route_path : route_path.chomp('/'))
        pattern = +'\A'
        until scanner.eos?
          pattern << if scanner.scan(/:\w+/) then '[^/.?]+'
                     elsif scanner.scan(/\*\w+/) then '.+'
                     elsif scanner.scan('(') then '(?:'
                     elsif scanner.scan(')') then ')?'
                     else Regexp.escape(scanner.getch)
                     end
        end
        Regexp.new("#{pattern}(?:\\.\\w+)?\\z")
      end

      # Controller and redirect routes of the live route set, in route order.
      #
      # @return [Array<Route>]
      def load_routes
        RouteExtractor.new.extract_all.filter_map do |unit|
          metadata = unit.metadata
          next unless metadata[:path] && (metadata[:action] || metadata[:kind] == 'redirect')

          build_route(unit.identifier, metadata, metadata[:path].to_s)
        end
      rescue StandardError
        []
      end

      def build_route(identifier, metadata, path)
        constraint = (metadata[:constraints] || {})[:subdomain]
        constraint = constraint.to_s unless constraint.nil? || constraint.is_a?(Regexp)
        Route.new(identifier: identifier, verb: metadata[:http_method].to_s, path: path,
                  name: metadata[:route_name]&.to_s, prefix: path[/\A[^:*(]*/].chomp('/'),
                  subdomain: constraint, callable: identifier.include?('constraint=proc'),
                  static: !path.match?(/[:*]/), redirect: metadata[:kind] == 'redirect')
      end
    end
  end
end
