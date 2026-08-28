# frozen_string_literal: true

require 'net/http'
require 'json'

module Woods
  # Standalone-load guard — keeps `require 'woods/embedding/provider'`
  # working without the top-level woods.rb (same pattern as storage/
  # and console/). {Provider::RequestError} subclasses this at load time.
  class Error < StandardError; end unless defined?(Woods::Error)

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

      # Raised when an embedding API answers with a non-success HTTP
      # response. Carries the HTTP status and the raw +Retry-After+ header
      # (when the server sent one) so {Woods::Resilience::RetryableProvider}
      # can distinguish transient failures (429 rate limits, 5xx) from
      # hopeless ones (400 bad request, 401 bad credentials) and honor the
      # server's requested back-off instead of its own schedule.
      #
      # Subclasses {Woods::Error}, so existing `rescue Woods::Error` call
      # sites keep working unchanged.
      class RequestError < Woods::Error
        # @return [Integer, nil] HTTP status code of the failed response
        attr_reader :http_status

        # @return [String, nil] raw +Retry-After+ header value (delta-seconds
        #   or HTTP-date form), or nil when the server sent none
        attr_reader :retry_after

        # @param message [String] human-readable error message
        # @param http_status [Integer, nil] HTTP status code
        # @param retry_after [String, nil] raw +Retry-After+ header value
        def initialize(message, http_status: nil, retry_after: nil)
          super(message)
          @http_status = http_status
          @retry_after = retry_after
        end
      end

      # Raised when a provider's embedding response is malformed: wrong
      # cardinality, missing/duplicate OpenAI response indexes, a
      # non-finite/non-numeric or empty vector, or a vector whose dimension
      # disagrees with the rest of the batch. Left unvalidated, any of
      # these stores nil or mis-paired vectors and silently corrupts the
      # vector store.
      class InvalidEmbeddingResponse < Woods::Error
        # @return [String] the provider label ("OpenAI", "Ollama")
        attr_reader :provider

        # @return [Integer] the number of texts in the request this response answers
        attr_reader :batch_size

        # @param message [String] what specifically was wrong with the response
        # @param provider [String] provider label
        # @param batch_size [Integer] number of texts requested
        def initialize(message, provider:, batch_size:)
          @provider = provider
          @batch_size = batch_size
          super("#{provider} embedding response invalid for batch of #{batch_size}: #{message}")
        end
      end

      # Shared response-shape validation for embedding providers. A short
      # or malformed provider response — fewer vectors than requested,
      # duplicate/missing OpenAI response indexes, a NaN/Infinity/nil
      # entry, or a dimension that drifts partway through a batch — would
      # otherwise store nil or mis-paired vectors with no error at all,
      # corrupting the index silently. Every provider's `embed`/
      # `embed_batch` must call {.validate!} before returning.
      module VectorValidation
        module_function

        # @param vectors [Array<Array<Numeric>>] vectors about to be returned/stored,
        #   in whatever order the caller has them (order doesn't matter for these checks)
        # @param expected_count [Integer] number of texts in the request
        # @param provider [String] provider label used in the raised error's message
        # @param indexes [Array<Integer>, nil] raw response `index` values, when the
        #   provider's wire format carries them (OpenAI). Ollama has no index field —
        #   its response order is positional — so callers pass nil there and this
        #   check is skipped.
        # @raise [InvalidEmbeddingResponse] on any violation
        # @return [void]
        def validate!(vectors, expected_count:, provider:, indexes: nil)
          fail_with = lambda do |msg|
            raise InvalidEmbeddingResponse.new(msg, provider: provider, batch_size: expected_count)
          end

          unless vectors.size == expected_count
            fail_with.call("expected #{expected_count} vector(s), got #{vectors.size}")
          end

          validate_indexes!(indexes, expected_count, fail_with) if indexes

          validate_vector_shapes!(vectors, fail_with)
        end

        # @api private
        def validate_indexes!(indexes, expected_count, fail_with)
          if indexes.any? { |i| !i.is_a?(Integer) }
            fail_with.call("response indexes must all be integers, got #{indexes.inspect}")
          end
          fail_with.call("response indexes are not unique: #{indexes.sort}") if indexes.uniq.size != indexes.size

          expected_indexes = (0...expected_count).to_a
          return if indexes.sort == expected_indexes

          fail_with.call("response indexes #{indexes.sort} do not cover 0..#{expected_count - 1}")
        end
        private_class_method :validate_indexes!

        # @api private
        def validate_vector_shapes!(vectors, fail_with)
          dimension = nil
          vectors.each_with_index do |vector, i|
            check_vector_shape!(vector, i, fail_with)
            dimension ||= vector.size
            next if vector.size == dimension

            fail_with.call("vector at position #{i} has dimension #{vector.size}, expected #{dimension}")
          end
        end
        private_class_method :validate_vector_shapes!

        # @api private
        def check_vector_shape!(vector, index, fail_with)
          unless vector.is_a?(Array) && !vector.empty?
            fail_with.call("vector at position #{index} is not a non-empty array (got #{vector.class})")
          end
          return if vector.all? { |n| n.is_a?(Numeric) && n.finite? }

          fail_with.call("vector at position #{index} contains a non-finite or non-numeric value")
        end
        private_class_method :check_vector_shape!
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
        # @param dimensions [Integer, nil] Requested output vector size.
        # @param read_timeout [Integer] HTTP read timeout in seconds.
        #   Bump this for slow / cold-start hosts or very large batches.
        def initialize(model: DEFAULT_MODEL, host: DEFAULT_HOST, num_ctx: nil,
                       dimensions: nil, read_timeout: DEFAULT_READ_TIMEOUT)
          @model = model
          @host = host
          @num_ctx = num_ctx || MODEL_CONTEXT_LENGTHS.fetch(model, FALLBACK_NUM_CTX)
          @dimensions = normalize_dimensions(dimensions)
          @read_timeout = read_timeout
          @uri = URI("#{host}/api/embed")
        end

        # Embed a single text string.
        #
        # @param text [String] the text to embed
        # @return [Array<Float>] the embedding vector
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the text is nil or empty (avoids provider 400)
        def embed(text)
          raise ArgumentError, 'embed(text) requires a non-empty string' if text.nil? || text.to_s.strip.empty?

          response = post_request(build_body(text))
          vectors = Array(response['embeddings'])
          VectorValidation.validate!(vectors, expected_count: 1, provider: 'Ollama')
          vectors.first
        end

        # Embed multiple texts in a single request.
        #
        # @param texts [Array<String>] the texts to embed
        # @return [Array<Array<Float>>] array of embedding vectors
        # @raise [Woods::Error] if the API returns an error
        # @raise [ArgumentError] if the array is empty or any element is nil/empty
        def embed_batch(texts)
          raise ArgumentError, 'embed_batch(texts) requires a non-empty array' if texts.nil? || texts.empty?
          if texts.any? { |t| t.nil? || t.to_s.strip.empty? }
            raise ArgumentError, 'embed_batch(texts) rejects nil/empty entries'
          end

          response = post_request(build_body(texts))
          vectors = Array(response['embeddings'])
          VectorValidation.validate!(vectors, expected_count: texts.size, provider: 'Ollama')
          vectors
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

        def normalize_dimensions(value)
          return if value.nil?

          dimensions = Integer(value)
          raise ArgumentError, "dimensions must be positive, got #{value.inspect}" unless dimensions.positive?

          dimensions
        end

        # Cap interpolated response bodies so misconfigured Ollama responses
        # (e.g. proxied HTML error pages) don't unbounded-leak into logs or
        # re-raised error messages.
        #
        # @param body [String, nil]
        # @return [String]
        def truncate_response_body(body)
          return '' if body.nil?

          s = body.to_s
          s.length > 500 ? "#{s[0, 500]}... [truncated]" : s
        end

        # Build the JSON body for an `/api/embed` call. Adds `options.num_ctx`
        # when configured — without it, Ollama silently truncates to 2048
        # tokens and returns 400 when the input exceeds that default.
        def build_body(input)
          body = { model: @model, input: input }
          body[:dimensions] = @dimensions if @dimensions
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

          raise request_error(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout, IOError
          # Connection dropped — reset and retry once
          discard_http_client
          begin
            response = http_client.request(request)
          rescue StandardError => retry_error
            raise Woods::Error, "Ollama API error (retry failed): #{retry_error.message}"
          end
          raise request_error(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        end

        # Build a {RequestError} from a non-success Ollama response,
        # attaching the HTTP status and any +Retry-After+ header so the
        # resilience layer can classify the failure and honor the
        # server-requested back-off.
        #
        # @param response [Net::HTTPResponse]
        # @return [RequestError]
        def request_error(response)
          RequestError.new(
            "Ollama API error: #{response.code} #{truncate_response_body(response.body)}",
            http_status: response.code.to_i,
            retry_after: response['Retry-After']
          )
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

        # Close a persistent connection before dropping the reference. Nil-ing
        # {#http_client} alone abandons the open socket — the descriptor stays
        # allocated until GC finalizes the object — so finish it first. Finish
        # raises IOError on a session that was never started, and a connection
        # that died mid-request can refuse to close cleanly; the rescue keeps
        # the discard best-effort and only guarantees the reference is dropped.
        #
        # @return [void]
        def discard_http_client
          @http_client&.finish
        rescue StandardError
          nil
        ensure
          @http_client = nil
        end
      end
    end
  end
end
