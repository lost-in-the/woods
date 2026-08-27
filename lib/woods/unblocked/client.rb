# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'woods'
require_relative '../retry_after'
require_relative 'rate_limiter'

module Woods
  module Unblocked
    # API error carrying the HTTP status code, so callers can branch on
    # status (e.g. treat a 404 on delete as "already gone") instead of
    # matching message strings. Subclasses Woods::Error, so existing
    # +rescue Woods::Error+ sites keep working unchanged.
    class ApiError < Woods::Error
      # @return [Integer] HTTP status code of the failed response
      attr_reader :status

      # @param message [String] Error message
      # @param status [Integer] HTTP status code — required, because callers
      #   branch on it (a nil status would silently miss every status check)
      def initialize(message, status:)
        super(message)
        @status = Integer(status)
      end
    end

    # REST client for the Unblocked API v1.
    #
    # Handles document and collection CRUD with rate limiting, retries,
    # and error handling. Uses Net::HTTP for zero external dependencies.
    #
    # @example
    #   client = Client.new(api_token: "ubk_...")
    #   client.put_document(
    #     collection_id: "uuid",
    #     title: "Order (model)",
    #     body: "# Order\n...",
    #     uri: "https://github.com/org/repo/blob/main/app/models/order.rb"
    #   )
    #
    class Client
      BASE_URL = 'https://getunblocked.com/api/v1'
      MAX_RETRIES = 3
      DEFAULT_TIMEOUT = 30
      # Max page size the list endpoint accepts (per API docs).
      PAGE_SIZE = 200
      # Repo-hosted Woods mark, used as the collection icon when none is given.
      # The live API rejects collection creation without an iconUrl (despite
      # the API docs marking it optional), so a working default matters.
      DEFAULT_ICON_URL = 'https://raw.githubusercontent.com/lost-in-the/woods/main/assets/woods-mark-black.svg'

      # HTTP methods safe to retry after *any* transient network failure —
      # repeating an idempotent request cannot double-apply an operation.
      # PUT belongs here because the documents endpoint is an upsert keyed
      # on `uri`. POST (create_collection) is deliberately absent: see
      # {#execute_http}.
      IDEMPOTENT_METHODS = %i[get put delete head].freeze

      # Network failures that provably occur before the server could have
      # processed the request (the connection was never established), so a
      # retry is safe even for non-idempotent verbs.
      PRE_REQUEST_ERRORS = [Net::OpenTimeout, Errno::ECONNREFUSED].freeze

      # Response codes potentially retried. 429 is safe for every verb — it
      # means the server throttled the request before processing it. 503 is
      # NOT unconditionally safe: that status proves the *origin* refused to
      # process the request, but it can also be synthesized by an
      # intermediary sitting in front of an origin that already committed
      # the write, so the response alone doesn't prove non-commitment.
      # {#request}'s `idempotent:` flag gates the 503 retry accordingly —
      # see {#execute_http} for the equivalent network-level split.
      RETRYABLE_STATUS_CODES = %w[429 503].freeze

      # @param api_token [String] Unblocked API token (Personal or Team)
      # @param rate_limiter [RateLimiter] Rate limiter instance
      # @raise [ArgumentError] if api_token is nil or empty
      def initialize(api_token:, rate_limiter: RateLimiter.new)
        raise ArgumentError, 'api_token is required' if api_token.nil? || api_token.to_s.strip.empty?

        @api_token = api_token
        @rate_limiter = rate_limiter
      end

      # Create or update a document (upsert by URI).
      #
      # Documents are unique by `uri` across the organization. If a document
      # with the given URI exists, it is updated; otherwise it is created.
      # Documents become available for queries within ~1 minute.
      #
      # @param collection_id [String] Target collection UUID
      # @param title [String] Document title (plain text)
      # @param body [String] Document body (Markdown preferred)
      # @param uri [String] Source URL (used as unique identifier and citation link)
      # @return [Hash] { "id" => "document-uuid" }
      def put_document(collection_id:, title:, body:, uri:)
        request(:put, 'documents', {
                  collectionId: collection_id,
                  title: title,
                  body: body,
                  uri: uri
                })
      end

      # Create a new collection.
      #
      # @param name [String] Collection name (1-32 chars)
      # @param description [String] Collection description (1-4096 chars)
      # @param icon_url [String, nil] Icon URL. The live API rejects creation
      #   with a bare 400 when omitted (despite the API docs marking it
      #   optional), so nil falls back to DEFAULT_ICON_URL — the repo-hosted
      #   Woods mark.
      # @return [Hash] { "id" => "collection-uuid", "name" => "...", ... }
      def create_collection(name:, description:, icon_url: nil)
        # Collections have no upsert key, so there's no idempotency key to
        # offer the API — a 503 that turns out to be an intermediary's
        # response for an already-committed create must not be retried.
        request(:post, 'collections', {
                  name: name,
                  description: description,
                  iconUrl: icon_url || DEFAULT_ICON_URL
                }, idempotent: false)
      end

      # Delete a document by ID.
      #
      # @param document_id [String] Document UUID
      # @return [Hash] API response
      def delete_document(document_id:)
        request(:delete, "documents/#{document_id}")
      end

      # List a single page of documents.
      #
      # The endpoint returns a bare JSON array of document metadata (no body):
      # `id, collectionId, title, uri, createdAt, updatedAt`. Pagination is
      # cursor-based via `after`/`before` (opaque cursors); there is no
      # server-side collection filter.
      #
      # @param limit [Integer] Page size (1-200)
      # @param after [String, nil] Opaque forward cursor (typically the last id)
      # @return [Array<Hash>] One page of document metadata
      def list_documents(limit: PAGE_SIZE, after: nil)
        query = "limit=#{limit}"
        query += "&after=#{URI.encode_www_form_component(after)}" if after
        result = request(:get, "documents?#{query}")
        return result if result.is_a?(Array)

        result['items'] || result['data'] || []
      end

      # List every document in a collection, paging until exhausted.
      #
      # Filters client-side on `collectionId` since the API has no collection
      # filter. ~5 calls for ~1000 documents; each goes through the rate limiter.
      #
      # @param collection_id [String] Collection UUID to filter to
      # @return [Array<Hash>] All matching document metadata
      def all_documents(collection_id:)
        docs = []
        after = nil

        loop do
          page = list_documents(limit: PAGE_SIZE, after: after)
          break if page.empty?

          docs.concat(page)
          break if page.size < PAGE_SIZE

          after = page.last['id']
          # A full page with no cursor id would refetch page 1 forever —
          # stop with what we have rather than loop against the budget.
          break if after.nil?
        end

        docs.select { |doc| doc['collectionId'] == collection_id }
      end

      private

      # @param method [Symbol] HTTP method
      # @param path [String] API path (appended to BASE_URL)
      # @param body [Hash, nil] Request body
      # @param idempotent [Boolean] Whether repeating this request cannot
      #   double-apply the operation. 429 always retries regardless; a 503
      #   only retries when `idempotent` is true, since a 503 can be an
      #   intermediary's response for an origin that already committed a
      #   non-idempotent write (see {RETRYABLE_STATUS_CODES}).
      # @raise [Woods::Error] on non-success responses (after retries for 429,
      #   and for 503 when idempotent), or immediately for a non-idempotent
      #   request's 503
      def request(method, path, body = nil, idempotent: true)
        retries = 0

        loop do
          response = @rate_limiter.track { execute_http(method, path, body) }

          return parse_response(response) if response.is_a?(Net::HTTPSuccess)

          raise_ambiguous_response_error(method, response) if response.code == '503' && !idempotent

          if RETRYABLE_STATUS_CODES.include?(response.code) && retries < MAX_RETRIES
            retries += 1
            # Retry-After may be an HTTP-date, which .to_f would collapse to
            # 0.0 — honoring it as-is would hammer a throttling server.
            wait_time = Woods::RetryAfter.seconds(response['Retry-After'], fallback: retries * 2)
            sleep(wait_time)
            next
          end

          raise_api_error(response)
        end
      end

      # Perform the raw HTTP request with verb-aware network error retry.
      #
      # Idempotent verbs ({IDEMPOTENT_METHODS}) retry every transient
      # failure. POST retries only failures that provably happened before
      # the server could have processed the request ({PRE_REQUEST_ERRORS});
      # a mid-exchange failure (Net::ReadTimeout, ECONNRESET) raises
      # instead, because the request may have been fully delivered and
      # committed server-side before the connection died. That matters here
      # because the one live POST is create_collection: collections have no
      # upsert key, so retrying a phantom-committed create mints a duplicate
      # collection that no later sync reconciles (documents upsert by `uri`
      # and are safe; collections are not).
      def execute_http(method, path, body)
        attempts = 0
        begin
          uri = URI("#{BASE_URL}/#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = DEFAULT_TIMEOUT
          http.read_timeout = DEFAULT_TIMEOUT

          req = build_request(method, uri, body)
          http.request(req)
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED => e
          raise_ambiguous_network_error(method, e) unless safe_to_retry?(method, e)

          attempts += 1
          if attempts >= MAX_RETRIES
            raise Woods::Error, "Network error after #{attempts} attempts: #{redact_token(e.message)}"
          end

          sleep(2**attempts)
          retry
        end
      end

      # Whether a failed request may be retried without risking a
      # double-apply: either the verb is idempotent, or the failure class
      # proves the request never reached the server.
      def safe_to_retry?(method, error)
        IDEMPOTENT_METHODS.include?(method) || PRE_REQUEST_ERRORS.any? { |klass| error.is_a?(klass) }
      end

      # Raise for a non-idempotent request that failed mid-exchange. The
      # request may have been committed server-side before the failure, so
      # the operator must verify (e.g. list collections) before re-running
      # rather than have the client silently duplicate the write.
      def raise_ambiguous_network_error(method, error)
        raise Woods::Error,
              "#{method.to_s.upcase} request interrupted mid-exchange (#{error.class}); " \
              'the operation may or may not have been applied server-side. ' \
              'Not retrying automatically to avoid duplicates; verify before re-running: ' \
              "#{redact_token(error.message)}"
      end

      # Raise for a non-idempotent request that received a 503. The response
      # doesn't prove the origin never processed the request — an
      # intermediary can synthesize a 503 for a request the origin already
      # committed — so this mirrors {#raise_ambiguous_network_error}: same
      # error class, same "verify before re-running" guidance, because the
      # risk (a silently duplicated create) is identical.
      #
      # @param method [Symbol] HTTP method
      # @param response [Net::HTTPResponse] the 503 response
      # @raise [Woods::Error] always
      def raise_ambiguous_response_error(method, response)
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError, TypeError
          {}
        end
        detail = parsed['message'] || parsed['detail'] || parsed['title'] || 'Service Unavailable'
        raise Woods::Error,
              "#{method.to_s.upcase} request received 503 (#{redact_token(detail)}); " \
              'the operation may or may not have been applied server-side. ' \
              'Not retrying automatically to avoid duplicates; verify before re-running.'
      end

      # Strip the bearer token out of anything derived from an underlying
      # network error before it reaches a log or a backtrace.
      #
      # The stdlib can echo a reflected URL or a request dump into an
      # exception message, and this client sends the token in an Authorization
      # header on every request. The Notion client has done this since its
      # audit; this one had not, so the same class of leak was still open here.
      #
      # @param message [String, nil]
      # @return [String, nil]
      def redact_token(message)
        return message if message.nil? || message.empty?
        return message if @api_token.nil? || @api_token.empty?

        message.to_s.gsub(@api_token, '[REDACTED]')
      end

      def build_request(method, uri, body)
        req = case method
              when :put then Net::HTTP::Put.new(uri)
              when :post then Net::HTTP::Post.new(uri)
              when :get then Net::HTTP::Get.new(uri)
              when :delete then Net::HTTP::Delete.new(uri)
              else raise ArgumentError, "Unsupported HTTP method: #{method}"
              end

        req['Authorization'] = "Bearer #{@api_token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body) if body

        req
      end

      def parse_response(response)
        return {} if response.body.nil? || response.body.strip.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end

      def raise_api_error(response)
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError, TypeError
          { 'message' => response.body&.slice(0, 200) || 'Unknown error' }
        end
        # The Unblocked API returns RFC7807-style bodies ({ status, title, detail });
        # older/other paths use message/error. Check all so failures stay legible.
        message = parsed['message'] || parsed['error'] || parsed['detail'] || parsed['title'] || 'Unknown error'
        raise ApiError.new("Unblocked API error #{response.code}: #{redact_token(message)}",
                           status: response.code.to_i)
      end
    end
  end
end
