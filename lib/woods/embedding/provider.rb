# frozen_string_literal: true

require 'net/http'
require 'json'

module Woods
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

        # Return the maximum input length the provider will accept for a
        # single text, in tokens. Used by the indexer to decide when a unit
        # must be chunked before embedding.
        #
        # @return [Integer, nil] token budget, or nil if the provider has no hard cap
        # @raise [NotImplementedError] if not implemented by the provider
        def max_input_tokens
          raise NotImplementedError
        end
      end

      # Ollama adapter for local embeddings via the Ollama HTTP API.
      #
      # Uses the `/api/embed` endpoint to generate embeddings. Requires a running
      # Ollama instance (default: localhost:11434) with the specified model pulled.
      #
      # @example
      #   provider = Woods::Embedding::Provider::Ollama.new
      #   vector = provider.embed("class User < ApplicationRecord; end")
      #   vectors = provider.embed_batch(["text1", "text2"])
      class Ollama
        include Interface

        DEFAULT_MODEL = 'nomic-embed-text'
        DEFAULT_HOST = 'http://localhost:11434'

        # Ollama enforces the model's native context length on `/api/embed`
        # regardless of the `num_ctx` override — we've validated this
        # against 0.15.x for nomic-embed-text (rejects >2048) and bge-m3
        # (accepts up to 8192, silently truncates above). Advertise the
        # native ceiling so the chunker can size inputs correctly. Models
        # outside this registry fall back to Ollama's conservative 2048
        # default.
        #
        # See `docs/EMBEDDING_MODELS.md` for the tradeoff matrix and
        # instructions for adding a new model here.
        MODEL_CONTEXT_LENGTHS = {
          'nomic-embed-text' => 2048,
          'bge-m3' => 8192,
          'mxbai-embed-large' => 512,
          'snowflake-arctic-embed' => 512,
          'snowflake-arctic-embed2' => 8192,
          # all-minilm: 512 is the model's context length, NOT the 384
          # embedding dimension and NOT the 256 some sources confuse with
          # the dimension. With a 256-token budget the chunker formula
          # produces a negative max_chars and silently drops every chunk.
          'all-minilm' => 512
        }.freeze

        # Fallback when the configured model isn't in the registry.
        FALLBACK_NUM_CTX = 2048

        # Default read timeout for /api/embed. The previous 30s default
        # was too short for batched embed calls on cold models — Ollama
        # has to load the model on first call, and an N-item batch can
        # easily exceed 30s on a CPU-only host. 120s leaves headroom
        # without wedging the whole pipeline on a genuinely dead server.
        DEFAULT_READ_TIMEOUT = 120

        # @param model [String] Ollama model name (default: nomic-embed-text).
        #   Set to `"bge-m3"` or `"snowflake-arctic-embed2"` for an 8192-token
        #   context and skip most chunking for dense Rails units.
        # @param host [String] Ollama server URL (default: http://localhost:11434)
        # @param num_ctx [Integer, nil] Ollama context window in tokens. When
        #   `nil` (the default), the provider picks the model's native
        #   context from `MODEL_CONTEXT_LENGTHS`, falling back to 2048 for
        #   unknown models. Set explicitly only if running a model with a
        #   known-larger native context that isn't in the registry yet.
        # @param read_timeout [Integer] HTTP read timeout in seconds.
        #   Bump this for slow / cold-start hosts or very large batches.
        def initialize(model: DEFAULT_MODEL, host: DEFAULT_HOST, num_ctx: nil,
                       read_timeout: DEFAULT_READ_TIMEOUT)
          @model = model
          @host = host
          @num_ctx = num_ctx || MODEL_CONTEXT_LENGTHS.fetch(model, FALLBACK_NUM_CTX)
          @read_timeout = read_timeout
          @uri = URI("#{host}/api/embed")
        end

        # Embed a single text string.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [Woods::Error] if the API returns an error
        def embed(text)
          response = post_request(build_body(text))
          response['embeddings'].first
        end

        # Embed multiple texts in a single request.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [Woods::Error] if the API returns an error
        def embed_batch(texts)
          response = post_request(build_body(texts))
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

        # Maximum input length Ollama will accept — tracks the configured
        # context window. Always populated: the constructor resolves
        # `num_ctx` to the model's registry entry or {FALLBACK_NUM_CTX},
        # so this method never returns nil for an Ollama provider.
        #
        # @return [Integer]
        def max_input_tokens
          @num_ctx
        end

        private

        # Build the JSON body for an `/api/embed` call. Adds `options.num_ctx`
        # when configured — without it, Ollama silently truncates to 2048
        # tokens and returns 400 when the input exceeds that default.
        def build_body(input)
          body = { model: @model, input: input }
          body[:options] = { num_ctx: @num_ctx } if @num_ctx
          body
        end

        # Send a POST request to the Ollama API.
        #
        # @param body [Hash] request body
        # @return [Hash] parsed JSON response
        # @raise [Woods::Error] if the API returns a non-success status
        def post_request(body)
          request = Net::HTTP::Post.new(@uri.path, 'Content-Type' => 'application/json')
          request.body = body.to_json
          response = http_client.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "Ollama API error: #{response.code} #{response.body}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          begin
            response = http_client.request(request)
          rescue StandardError => retry_error
            raise Woods::Error, "Ollama API error (retry failed): #{retry_error.message}"
          end
          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "Ollama API error: #{response.code} #{response.body}"
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
          http.read_timeout = @read_timeout
          http.keep_alive_timeout = 30
          http.start
          @http_client = http
        end
      end
    end
  end
end
