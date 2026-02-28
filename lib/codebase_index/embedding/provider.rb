# frozen_string_literal: true

require 'net/http'
require 'json'

module CodebaseIndex
  module Embedding
    # Interface and adapters for embedding providers.
    #
    # All embedding providers implement the {Interface} module, which defines
    # the contract for generating vector embeddings from text.
    module Provider
      # Interface that all embedding providers must implement.
      #
      # Defines the contract for embedding text into vector representations.
      # Implementations must provide single-text embedding, batch embedding,
      # dimension reporting, and model identification.
      module Interface
        # Embed a single text string into a vector.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [NotImplementedError] if not implemented by the provider
        def embed(text)
          raise NotImplementedError
        end

        # Embed multiple texts into vectors in a single request.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [NotImplementedError] if not implemented by the provider
        def embed_batch(texts)
          raise NotImplementedError
        end

        # Return the dimensionality of the embedding vectors.
        #
        # @return [Integer] number of dimensions
        # @raise [NotImplementedError] if not implemented by the provider
        def dimensions
          raise NotImplementedError
        end

        # Return the name of the embedding model.
        #
        # @return [String] model name
        # @raise [NotImplementedError] if not implemented by the provider
        def model_name
          raise NotImplementedError
        end
      end

      # Ollama adapter for local embeddings via the Ollama HTTP API.
      #
      # Uses the `/api/embed` endpoint to generate embeddings. Requires a running
      # Ollama instance (default: localhost:11434) with the specified model pulled.
      #
      # @example
      #   provider = CodebaseIndex::Embedding::Provider::Ollama.new
      #   vector = provider.embed("class User < ApplicationRecord; end")
      #   vectors = provider.embed_batch(["text1", "text2"])
      class Ollama
        include Interface

        DEFAULT_MODEL = 'nomic-embed-text'
        DEFAULT_HOST = 'http://localhost:11434'

        # @param model [String] Ollama model name (default: nomic-embed-text)
        # @param host [String] Ollama server URL (default: http://localhost:11434)
        def initialize(model: DEFAULT_MODEL, host: DEFAULT_HOST)
          @model = model
          @host = host
          @uri = URI("#{host}/api/embed")
        end

        # Embed a single text string.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [CodebaseIndex::Error] if the API returns an error
        def embed(text)
          response = post_request({ model: @model, input: text })
          response['embeddings'].first
        end

        # Embed multiple texts in a single request.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [CodebaseIndex::Error] if the API returns an error
        def embed_batch(texts)
          response = post_request({ model: @model, input: texts })
          response['embeddings']
        end

        # Return the dimensionality of vectors produced by this model.
        #
        # Determined dynamically by embedding a test string on first call.
        #
        # @return [Integer] number of dimensions
        def dimensions
          @dimensions ||= embed('test').length
        end

        # Return the model name.
        #
        # @return [String] the Ollama model name
        def model_name
          @model
        end

        private

        # Send a POST request to the Ollama API.
        #
        # @param body [Hash] request body
        # @return [Hash] parsed JSON response
        # @raise [CodebaseIndex::Error] if the API returns a non-success status
        def post_request(body)
          request = Net::HTTP::Post.new(@uri.path, 'Content-Type' => 'application/json')
          request.body = body.to_json
          response = http_client.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "Ollama API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          response = http_client.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            raise CodebaseIndex::Error, "Ollama API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        end

        # Return a reusable, started HTTP client for the Ollama API.
        #
        # @return [Net::HTTP]
        def http_client
          return @http_client if @http_client&.started?

          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == 'https'
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
