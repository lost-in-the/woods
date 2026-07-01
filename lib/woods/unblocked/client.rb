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
        request(:post, 'collections', {
                  name: name,
                  description: description,
                  iconUrl: icon_url || DEFAULT_ICON_URL
                })
      end

      # List all collections.
      #
      # @return [Array<Hash>] Collection objects
      def list_collections
        result = request(:get, 'collections')
        # The live API returns a bare JSON array; the envelope fallbacks are
        # defensive (calling ['items'] on an Array raises TypeError).
        return result if result.is_a?(Array)

        result['items'] || result['data'] || [result].flatten.compact
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

      def request(method, path, body = nil)
        retries = 0

        loop do
          response = @rate_limiter.track { execute_http(method, path, body) }

          return parse_response(response) if response.is_a?(Net::HTTPSuccess)

          if response.code == '429' && retries < MAX_RETRIES
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
          attempts += 1
          raise Woods::Error, "Network error after #{attempts} retries: #{e.message}" if attempts > MAX_RETRIES

          sleep(2**attempts)
          retry
        end
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
        raise ApiError.new("Unblocked API error #{response.code}: #{message}", status: response.code.to_i)
      end
    end
  end
end
