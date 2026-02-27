# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'codebase_index'
require_relative 'rate_limiter'

module CodebaseIndex
  module Notion
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
      # @raise [CodebaseIndex::Error] on non-success responses (after retries for 429)
      def request(method, path, body = nil)
        retries = 0

        loop do
          response = execute_with_retry(method, path, body, retries)

          return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

          if response.code == '429' && retries < MAX_RETRIES
            retries += 1
            wait_time = (response['Retry-After'] || retries).to_f
            sleep(wait_time)
            next
          end

          raise_api_error(response)
        end
      end

      # Execute HTTP with rate limiting and network error retry.
      #
      # @return [Net::HTTPResponse]
      # @raise [CodebaseIndex::Error] on persistent network failures
      def execute_with_retry(method, path, body, _retries)
        attempts = 0
        begin
          @rate_limiter.throttle { execute_http(method, path, body) }
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED => e
          attempts += 1
          raise CodebaseIndex::Error, "Network error after #{attempts} retries: #{e.message}" if attempts >= MAX_RETRIES

          sleep(2**attempts)
          retry
        end
      end

      # Raise a descriptive error from a non-success Notion response.
      #
      # @raise [CodebaseIndex::Error]
      def raise_api_error(response)
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          { 'message' => "Unparseable response body: #{response.body&.slice(0, 200)}" }
        end
        message = parsed['message'] || 'Unknown error'
        raise CodebaseIndex::Error, "Notion API error #{response.code}: #{message}"
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
