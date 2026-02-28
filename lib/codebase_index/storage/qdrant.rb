# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require_relative 'vector_store'

module CodebaseIndex
  module Storage
    module VectorStore
      # Qdrant adapter for vector storage and similarity search via HTTP API.
      #
      # Communicates with a Qdrant instance over HTTP. Supports optional API key
      # authentication for managed/cloud deployments.
      #
      # @example
      #   store = Qdrant.new(url: "http://localhost:6333", collection: "codebase")
      #   store.ensure_collection!(dimensions: 768)
      #   store.store("User", [0.1, 0.2, ...], { type: "model" })
      #   results = store.search([0.1, 0.2, ...], limit: 5)
      #
      class Qdrant # rubocop:disable Metrics/ClassLength
        include Interface

        # @param url [String] Qdrant server URL
        # @param collection [String] Collection name
        # @param api_key [String, nil] Optional API key for authentication
        def initialize(url:, collection:, api_key: nil)
          @url = url
          @collection = collection
          @api_key = api_key
          @uri = URI(url)
        end

        # Create the collection if it doesn't exist.
        #
        # @param dimensions [Integer] Vector dimensionality
        def ensure_collection!(dimensions:)
          body = {
            vectors: {
              size: dimensions,
              distance: 'Cosine'
            }
          }
          request(:put, "/collections/#{@collection}", body)
        end

        # Store or update a vector with metadata payload.
        #
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] The embedding vector
        # @param metadata [Hash] Optional payload metadata
        # @see Interface#store
        def store(id, vector, metadata = {})
          body = {
            points: [
              {
                id: id,
                vector: vector,
                payload: metadata
              }
            ]
          }
          request(:put, "/collections/#{@collection}/points", body)
        end

        # Store multiple vectors in a single batch upsert request.
        #
        # @param entries [Array<Hash>] Each entry has :id, :vector, :metadata keys
        def store_batch(entries)
          return if entries.empty?

          body = {
            points: entries.map do |entry|
              { id: entry[:id], vector: entry[:vector], payload: entry[:metadata] || {} }
            end
          }
          request(:put, "/collections/#{@collection}/points", body)
        end

        # Search for similar vectors.
        #
        # @param query_vector [Array<Float>] The query embedding
        # @param limit [Integer] Maximum results to return
        # @param filters [Hash] Metadata key-value filters
        # @return [Array<SearchResult>] Results sorted by descending similarity
        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          body = {
            vector: query_vector,
            limit: limit,
            with_payload: true
          }
          body[:filter] = build_filter(filters) unless filters.empty?

          response = request(:post, "/collections/#{@collection}/points/search", body)
          results = response['result'] || []

          results.map do |hit|
            SearchResult.new(
              id: hit['id'],
              score: hit['score'],
              metadata: hit['payload']
            )
          end
        end

        # @see Interface#delete
        def delete(id)
          body = { points: [id] }
          request(:post, "/collections/#{@collection}/points/delete", body)
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          body = { filter: build_filter(filters) }
          request(:post, "/collections/#{@collection}/points/delete", body)
        end

        # @see Interface#count
        def count
          response = request(:post, "/collections/#{@collection}/points/count", { exact: true })
          response['result']['count']
        end

        private

        # Build a Qdrant filter from metadata key-value pairs.
        #
        # @param filters [Hash] Metadata filters
        # @return [Hash] Qdrant-compatible filter with must conditions
        def build_filter(filters)
          conditions = filters.map do |key, value|
            { key: key.to_s, match: { value: value } }
          end
          { must: conditions }
        end

        # Send an HTTP request to the Qdrant API.
        #
        # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
        # @param path [String] API path
        # @param body [Hash, nil] Request body
        # @return [Hash] Parsed JSON response
        # @raise [CodebaseIndex::Error] if the API returns a non-success status
        def request(method, path, body = nil)
          req = build_request(method, path, body)
          response = http_client.request(req)

          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "Qdrant API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          response = http_client.request(req)
          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "Qdrant API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        end

        # Return a reusable HTTP client for the Qdrant server.
        # Lazily created and kept alive across requests to avoid
        # TCP handshake overhead on every call.
        #
        # @return [Net::HTTP]
        def http_client
          @http_client ||= begin
            http = Net::HTTP.new(@uri.host, @uri.port)
            http.use_ssl = @uri.scheme == 'https'
            http.open_timeout = 10
            http.read_timeout = 30
            http.keep_alive_timeout = 30
            http
          end
        end

        # Build an HTTP request with headers and body.
        #
        # @param method [Symbol] HTTP method
        # @param path [String] API path
        # @param body [Hash, nil] Request body
        # @return [Net::HTTPRequest]
        def build_request(method, path, body)
          request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post,
                            put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
          req = request_class.new(path, 'Content-Type' => 'application/json')
          req['api-key'] = @api_key if @api_key
          req.body = body.to_json if body
          req
        end
      end
    end
  end
end
