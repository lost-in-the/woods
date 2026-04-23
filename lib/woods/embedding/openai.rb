# frozen_string_literal: true

require 'net/http'
require 'json'

module Woods
  module Embedding
    module Provider
      # OpenAI adapter for cloud embeddings via the OpenAI HTTP API.
      #
      # Uses the `/v1/embeddings` endpoint to generate embeddings. Requires a valid
      # OpenAI API key.
      #
      # @example
      #   provider = Woods::Embedding::Provider::OpenAI.new(api_key: ENV['OPENAI_API_KEY'])
      #   vector = provider.embed("class User < ApplicationRecord; end")
      #   vectors = provider.embed_batch(["text1", "text2"])
      class OpenAI
        include Interface

        ENDPOINT = URI('https://api.openai.com/v1/embeddings')
        DEFAULT_MODEL = 'text-embedding-3-small'
        DIMENSIONS = {
          'text-embedding-3-small' => 1536,
          'text-embedding-3-large' => 3072
        }.freeze
        # OpenAI embedding models share an 8191-token input cap across
        # text-embedding-3-small / -3-large / ada-002. The chunker uses
        # this as a hard ceiling — the actual chunk size lands well
        # below it once chars-per-token estimation and the prefix
        # allowance are factored in (see Builder#build_chunker).
        MAX_INPUT_TOKENS = 8191

        # @param api_key [String] OpenAI API key
        # @param model [String] OpenAI embedding model name (default: text-embedding-3-small)
        def initialize(api_key:, model: DEFAULT_MODEL)
          @api_key = api_key
          @model = model
        end

        # Embed a single text string.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the text is nil or empty (OpenAI rejects these with 400)
        def embed(text)
          raise ArgumentError, 'embed(text) requires a non-empty string' if text.nil? || text.to_s.strip.empty?

          response = post_request({ model: @model, input: text })
          response['data'].first['embedding']
        end

        # Embed multiple texts in a single request.
        #
        # Sorts results by the index field to guarantee ordering matches input.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the array is empty or any element is nil/empty
        def embed_batch(texts) # rubocop:disable Metrics/CyclomaticComplexity
          raise ArgumentError, 'embed_batch(texts) requires a non-empty array' if texts.nil? || texts.empty?
          if texts.any? { |t| t.nil? || t.to_s.strip.empty? }
            raise ArgumentError, 'embed_batch(texts) rejects nil/empty entries (OpenAI returns 400)'
          end

          response = post_request({ model: @model, input: texts })
          response['data']
            .sort_by { |item| item['index'] }
            .map { |item| item['embedding'] }
        end

        # Return the dimensionality of vectors produced by this model.
        #
        # Uses the known dimensions for standard models, falling back to a
        # test embedding for unknown models.
        #
        # @return [Integer] number of dimensions
        def dimensions
          DIMENSIONS[@model] || embed('test').length
        end

        # Return the model name.
        #
        # @return [String] the OpenAI model name
        def model_name
          @model
        end

        # Maximum input length OpenAI will accept for a single embedding
        # text. All current text-embedding-* models cap at ~8k tokens.
        #
        # @return [Integer]
        def max_input_tokens
          MAX_INPUT_TOKENS
        end

        private

        # Send a POST request to the OpenAI embeddings API.
        #
        # @param body [Hash] request body
        # @return [Hash] parsed JSON response
        # @raise [Woods::Error] if the API returns a non-success status
        def post_request(body)
          request = Net::HTTP::Post.new(ENDPOINT.path)
          request['Content-Type'] = 'application/json'
          request['Authorization'] = "Bearer #{@api_key}"
          request.body = body.to_json

          response = http_client.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "OpenAI API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          response = http_client.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "OpenAI API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        end

        # Return a reusable, started HTTP client for the OpenAI API.
        # Calling http.start opens a persistent TCP connection so
        # keep_alive_timeout actually takes effect across requests.
        #
        # @return [Net::HTTP]
        def http_client
          return @http_client if @http_client&.started?

          http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
          http.use_ssl = true
          http.open_timeout = 10
          http.read_timeout = 30
          http.keep_alive_timeout = 30
          http.start
          @http_client = http
        end
      end
    end
  end
end
