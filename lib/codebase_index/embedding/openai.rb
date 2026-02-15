# frozen_string_literal: true

require 'net/http'
require 'json'

module CodebaseIndex
  module Embedding
    module Provider
      # OpenAI adapter for cloud embeddings via the OpenAI HTTP API.
      #
      # Uses the `/v1/embeddings` endpoint to generate embeddings. Requires a valid
      # OpenAI API key.
      #
      # @example
      #   provider = CodebaseIndex::Embedding::Provider::OpenAI.new(api_key: ENV['OPENAI_API_KEY'])
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
        # @raise [CodebaseIndex::Error] if the API returns an error
        def embed(text)
          response = post_request({ model: @model, input: text })
          response['data'].first['embedding']
        end

        # Embed multiple texts in a single request.
        #
        # Sorts results by the index field to guarantee ordering matches input.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [CodebaseIndex::Error] if the API returns an error
        def embed_batch(texts)
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

        private

        # Send a POST request to the OpenAI embeddings API.
        #
        # @param body [Hash] request body
        # @return [Hash] parsed JSON response
        # @raise [CodebaseIndex::Error] if the API returns a non-success status
        def post_request(body)
          http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
          http.use_ssl = true

          request = Net::HTTP::Post.new(ENDPOINT.path)
          request['Content-Type'] = 'application/json'
          request['Authorization'] = "Bearer #{@api_key}"
          request.body = body.to_json

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "OpenAI API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        end
      end
    end
  end
end
