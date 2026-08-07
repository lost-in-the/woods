# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'woods'
require_relative '../retry_after'
require_relative 'rate_limiter'

module Woods
  module Notion
    # Raised on a 401/403 from the Notion API.
    #
    # A distinct class because authentication failure is not a per-unit
    # problem: a bad or unshared token dooms every remaining call in the run.
    # Without it the exporter's per-unit rescue recorded one error per unit and
    # kept going, so a wrong token spent the entire cold sync at Notion's 3
    # req/sec before reporting failure for everything. Subclasses
    # {Woods::Error}, so existing `rescue Woods::Error` sites are unaffected.
    class AuthenticationError < Woods::Error; end

    # Thin wrapper around the Notion REST API (v2022-06-28).
    #
    # Uses Net::HTTP (stdlib) for zero external dependencies. All requests are
    # throttled through a {RateLimiter} to respect Notion's 3 req/sec limit.
    #
    # @example
    #   client = Client.new(api_token: "secret_...")
    #   client.create_page(database_id: "db-uuid", properties: { ... })
    #   client.query_database(database_id: "db-uuid", filter: { ... })
    #
    class Client # rubocop:disable Metrics/ClassLength
      BASE_URL = 'https://api.notion.com/v1'
      NOTION_VERSION = '2022-06-28'
      MAX_RETRIES = 3
      DEFAULT_TIMEOUT = 30

      # Statuses that mean the credential itself is the problem, so no later
      # request in this run can succeed either. Response codes arrive as
      # strings from Net::HTTP.
      AUTH_STATUS_CODES = %w[401 403].freeze

      # HTTP methods safe to retry after *any* transient network failure —
      # repeating an idempotent request cannot double-apply an operation.
      # POST and PATCH are deliberately absent: see {#execute_with_retry}.
      IDEMPOTENT_METHODS = %i[get put delete head].freeze

      # Network failures that provably occur before the server could have
      # processed the request (the connection was never established), so a
      # retry is safe even for non-idempotent verbs.
      PRE_REQUEST_ERRORS = [Net::OpenTimeout, Errno::ECONNREFUSED].freeze

      # Response codes retried for every verb: the server answered without
      # committing the operation (429 = throttled before processing,
      # 503 = refused service), so a retry cannot duplicate anything.
      RETRYABLE_STATUS_CODES = %w[429 503].freeze

      # @param api_token [String] Notion integration API token
      # @param rate_limiter [RateLimiter] Rate limiter instance (default: 3 req/sec)
      # @raise [ArgumentError] if api_token is nil or empty
      def initialize(api_token:, rate_limiter: RateLimiter.new)
        raise ArgumentError, 'api_token is required' if api_token.nil? || api_token.to_s.empty?

        @api_token = api_token
        @rate_limiter = rate_limiter
      end

      # Create a page in a Notion database.
      #
      # @param database_id [String] Target database UUID
      # @param properties [Hash] Page properties in Notion API format
      # @param children [Array<Hash>] Optional page content blocks
      # @return [Hash] Created page data
      def create_page(database_id:, properties:, children: [])
        body = {
          parent: { database_id: database_id },
          properties: properties
        }
        body[:children] = children if children.any?

        request(:post, 'pages', body)
      end

      # Update an existing page's properties.
      #
      # @param page_id [String] Page UUID to update
      # @param properties [Hash] Properties to update
      # @return [Hash] Updated page data
      def update_page(page_id:, properties:)
        request(:patch, "pages/#{page_id}", { properties: properties })
      end

      # Query a database with optional filter and sort.
      #
      # @param database_id [String] Database UUID
      # @param filter [Hash, nil] Notion filter object
      # @param sorts [Array<Hash>, nil] Notion sort objects
      # @return [Hash] Query results with 'results', 'has_more', 'next_cursor'
      def query_database(database_id:, filter: nil, sorts: nil)
        body = {}
        body[:filter] = filter if filter
        body[:sorts] = sorts if sorts

        request(:post, "databases/#{database_id}/query", body)
      end

      # Query all pages from a database, auto-paginating.
      #
      # @param database_id [String] Database UUID
      # @param filter [Hash, nil] Notion filter object
      # @return [Array<Hash>] All matching pages
      def query_all(database_id:, filter: nil)
        all_results = []
        cursor = nil

        loop do
          body = {}
          body[:filter] = filter if filter
          body[:start_cursor] = cursor if cursor

          response = request(:post, "databases/#{database_id}/query", body)
          all_results.concat(response['results'] || [])

          break unless response['has_more']

          cursor = response['next_cursor']
        end

        all_results
      end

      # Find a page by its title property value.
      #
      # @param database_id [String] Database UUID
      # @param title [String] Title text to search for
      # @return [Hash, nil] First matching page or nil
      def find_page_by_title(database_id:, title:)
        response = query_database(
          database_id: database_id,
          filter: {
            property: 'title',
            title: { equals: title }
          }
        )

        results = response['results'] || []
        results.first
      end

      private

      # Execute an HTTP request against the Notion API.
      #
      # @param method [Symbol] HTTP method (:post, :patch, :get)
      # @param path [String] API path (appended to BASE_URL)
      # @param body [Hash, nil] Request body
      # @return [Hash] Parsed JSON response
      # @raise [Woods::Error] on non-success responses (after retries for 429/503)
      def request(method, path, body = nil)
        retries = 0

        loop do
          response = execute_with_retry(method, path, body)

          return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

          if RETRYABLE_STATUS_CODES.include?(response.code) && retries < MAX_RETRIES
            retries += 1
            # Retry-After may be an HTTP-date, which .to_f would collapse to
            # 0.0 — honoring it as-is would hammer a throttling server.
            wait_time = Woods::RetryAfter.seconds(response['Retry-After'], fallback: retries)
            sleep(wait_time)
            next
          end

          raise_api_error(response)
        end
      end

      # Execute HTTP with rate limiting and verb-aware network error retry.
      #
      # Retry classification depends on the verb. Idempotent verbs
      # ({IDEMPOTENT_METHODS}) retry every transient failure. Non-idempotent
      # verbs (POST, PATCH) retry only failures that provably happened before
      # the server could have processed the request ({PRE_REQUEST_ERRORS});
      # a mid-exchange failure (Net::ReadTimeout, ECONNRESET) raises instead,
      # because the request may have been fully delivered and committed
      # server-side before the connection died — retrying a phantom-committed
      # POST creates a duplicate object. For pages the exporter's
      # find-then-create upsert catches the duplicate on the *next* run and
      # updates it in place, but a duplicated database has no such
      # reconciliation, so a blind retry here is silent, permanent
      # duplication in the workspace.
      #
      # Any message from an underlying network error is run through
      # {#redact_token} before being re-raised — a malformed reflected
      # URL or request dump from the stdlib must not leak the bearer
      # token into logs or backtraces.
      #
      # @param method [Symbol] HTTP method, used to classify retryability
      # @return [Net::HTTPResponse]
      # @raise [Woods::Error] on persistent network failures, or immediately
      #   when a non-idempotent request fails ambiguously mid-exchange
      def execute_with_retry(method, path, body)
        attempts = 0
        begin
          @rate_limiter.throttle { execute_http(method, path, body) }
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED => e
          raise_ambiguous_network_error(method, e) unless safe_to_retry?(method, e)

          attempts += 1
          if attempts >= MAX_RETRIES
            raise Woods::Error,
                  "Network error after #{attempts} retries: #{redact_token(e.message)}"
          end

          sleep(2**attempts)
          retry
        end
      end

      # Whether a failed request may be retried without risking a
      # double-apply: either the verb is idempotent, or the failure class
      # proves the request never reached the server.
      #
      # @param method [Symbol] HTTP method
      # @param error [Exception] the network failure
      # @return [Boolean]
      def safe_to_retry?(method, error)
        IDEMPOTENT_METHODS.include?(method) || PRE_REQUEST_ERRORS.any? { |klass| error.is_a?(klass) }
      end

      # Raise for a non-idempotent request that failed mid-exchange. The
      # request may have been committed server-side before the failure, so
      # the operator must verify workspace state before re-running rather
      # than have the client silently duplicate the write.
      #
      # @param method [Symbol] HTTP method
      # @param error [Exception] the ambiguous network failure
      # @raise [Woods::Error] always
      def raise_ambiguous_network_error(method, error)
        raise Woods::Error,
              "#{method.to_s.upcase} request interrupted mid-exchange (#{error.class}); " \
              'the operation may or may not have been applied server-side. ' \
              "Not retrying automatically to avoid duplicates; verify before re-running: #{redact_token(error.message)}"
      end

      # Raise a descriptive error from a non-success Notion response.
      # The response body is scrubbed before being formatted into the
      # exception — if the Notion API ever echoes back a header (or a
      # proxy does), the bearer token must not surface here.
      #
      # @raise [Woods::Error]
      def raise_api_error(response)
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          { 'message' => "Unparseable response body: #{response.body&.slice(0, 200)}" }
        end
        message = parsed['message'] || 'Unknown error'
        error_class = AUTH_STATUS_CODES.include?(response.code) ? AuthenticationError : Woods::Error
        raise error_class,
              "Notion API error #{response.code}: #{redact_token(message)}"
      end

      # Replace every occurrence of the bearer token with `[REDACTED]`.
      # Defense in depth — no exception message emitted by this client
      # should carry the secret even if a future code path embeds the
      # request headers verbatim.
      def redact_token(message)
        return message if message.nil? || message.empty?
        return message if @api_token.nil? || @api_token.empty?

        message.to_s.gsub(@api_token, '[REDACTED]')
      end

      # Perform the raw HTTP request.
      #
      # @param method [Symbol] HTTP method
      # @param path [String] API path
      # @param body [Hash, nil] Request body
      # @return [Net::HTTPResponse]
      def execute_http(method, path, body)
        uri = URI("#{BASE_URL}/#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = DEFAULT_TIMEOUT
        http.read_timeout = DEFAULT_TIMEOUT

        req = build_request(method, uri, body)
        http.request(req)
      end

      # Build an HTTP request object with headers.
      #
      # @param method [Symbol] HTTP method
      # @param uri [URI] Full request URI
      # @param body [Hash, nil] Request body
      # @return [Net::HTTPRequest]
      def build_request(method, uri, body)
        req = case method
              when :post then Net::HTTP::Post.new(uri)
              when :patch then Net::HTTP::Patch.new(uri)
              when :get then Net::HTTP::Get.new(uri)
              else raise ArgumentError, "Unsupported HTTP method: #{method}"
              end

        req['Authorization'] = "Bearer #{@api_token}"
        req['Notion-Version'] = NOTION_VERSION
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body) if body

        req
      end
    end
  end
end
