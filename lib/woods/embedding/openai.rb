# frozen_string_literal: true

require 'net/http'
require 'json'
require_relative 'provider'

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
        # @param dimensions [Integer, nil] Requested output size for text-embedding-3 models
        def initialize(api_key:, model: DEFAULT_MODEL, dimensions: nil)
          @api_key = api_key
          @model = model
          @dimensions = normalize_dimensions(dimensions)
        end

        # Embed a single text string.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the text is nil or empty (OpenAI rejects these with 400)
        def embed(text)
          raise ArgumentError, 'embed(text) requires a non-empty string' if text.nil? || text.to_s.strip.empty?

          response = post_request(request_body(text))
          vectors = Array(response['data']).map { |item| item['embedding'] }
          VectorValidation.validate!(vectors, expected_count: 1, provider: 'OpenAI')
          vectors.first
        end

        # Embed multiple texts in a single request.
        #
        # Sorts results by the index field to guarantee ordering matches input.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the array is empty or any element is nil/empty
        def embed_batch(texts)
          raise ArgumentError, 'embed_batch(texts) requires a non-empty array' if texts.nil? || texts.empty?
          if texts.any? { |t| t.nil? || t.to_s.strip.empty? }
            raise ArgumentError, 'embed_batch(texts) rejects nil/empty entries (OpenAI returns 400)'
          end

          response = post_request(request_body(texts))
          extract_validated_batch(response, texts.size)
        end

        # Return the dimensionality of vectors produced by this model.
        #
        # Uses the known dimensions for standard models, falling back to a
        # test embedding for unknown models.
        #
        # @return [Integer] number of dimensions
        def dimensions
          @dimensions || DIMENSIONS[@model] || embed('test').length
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

        # Validate the batch response's shape/cardinality/indexes and
        # return vectors reordered to match the input order.
        #
        # @param response [Hash] parsed JSON response
        # @param expected_count [Integer] number of texts requested
        # @return [Array<Array<Float>>]
        def extract_validated_batch(response, expected_count)
          data = Array(response['data'])
          VectorValidation.validate!(
            data.map { |item| item['embedding'] },
            expected_count: expected_count,
            provider: 'OpenAI',
            indexes: data.map { |item| item['index'] }
          )
          data.sort_by { |item| item['index'] }.map { |item| item['embedding'] }
        end

        def request_body(input)
          { model: @model, input: input }.tap do |body|
            body[:dimensions] = @dimensions if @dimensions
          end
        end

        def normalize_dimensions(value)
          return if value.nil?

          dimensions = Integer(value)
          raise ArgumentError, "dimensions must be positive, got #{value.inspect}" unless dimensions.positive?

          dimensions
        end

        # Cap interpolated response bodies so misconfigured API errors
        # (which occasionally echo request metadata, including headers) don't
        # unbounded-leak into logs or re-raised messages.
        #
        # @param body [String, nil]
        # @return [String]
        def truncate_response_body(body)
          return '' if body.nil?

          s = body.to_s
          s.length > 500 ? "#{s[0, 500]}... [truncated]" : s
        end

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

          raise request_error(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          response = http_client.request(request)
          raise request_error(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        end

        # Build a {RequestError} from a non-success OpenAI response,
        # attaching the HTTP status and any +Retry-After+ header so the
        # resilience layer can classify the failure (429/5xx retryable,
        # 400/401 not) and honor the server-requested back-off.
        #
        # @param response [Net::HTTPResponse]
        # @return [RequestError]
        def request_error(response)
          RequestError.new(
            "OpenAI API error: #{response.code} #{truncate_response_body(response.body)}",
            http_status: response.code.to_i,
            retry_after: response['Retry-After']
          )
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
