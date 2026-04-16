# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'rate_limiter'

module Woods
  module Unblocked
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
      # @param icon_url [String, nil] Optional icon URL
      # @return [Hash] { "id" => "collection-uuid", "name" => "...", ... }
      def create_collection(name:, description:, icon_url: nil)
        body = { name: name, description: description }
        body[:iconUrl] = icon_url if icon_url
        request(:post, 'collections', body)
      end

      # List all collections.
      #
      # @return [Array<Hash>] Collection objects
      def list_collections
        result = request(:get, 'collections')
        result['items'] || result['data'] || [result].flatten.compact
      end

      # Delete a document by ID.
      #
      # @param document_id [String] Document UUID
      # @return [Hash] API response
      def delete_document(document_id:)
        request(:delete, "documents/#{document_id}")
      end

      private

      def request(method, path, body = nil)
        retries = 0

        loop do
          response = @rate_limiter.track { execute_http(method, path, body) }

          return parse_response(response) if response.is_a?(Net::HTTPSuccess)

          if response.code == '429' && retries < MAX_RETRIES
            retries += 1
            wait_time = (response['Retry-After'] || (retries * 2)).to_f
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
        message = parsed['message'] || parsed['error'] || 'Unknown error'
        raise Woods::Error, "Unblocked API error #{response.code}: #{message}"
      end
    end
  end
end
