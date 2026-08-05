# frozen_string_literal: true

require 'net/http'
require 'uri'

require_relative 'errors'
require_relative '../embedding/provider'
require_relative '../embedding/openai'
require_relative '../embedding/fake'

module Woods
  module MCP
    # Probes an embedding provider's HTTP endpoint to confirm it is reachable
    # before the MCP server commits to a fully-hydrated start.
    #
    # A probe is pure: input → result-or-raise. No logging, no stderr writes,
    # no side effects. The caller decides what to do with a failure.
    #
    # Raises {Woods::MCP::ProviderUnreachable} on any network failure with
    # structured +url:+ and +reason:+ fields so callers can pattern-match on
    # the reason string. Raises +ArgumentError+ for unknown provider classes —
    # that is a programming error, not a runtime condition.
    #
    # @example
    #   Woods::MCP::ProviderProbe.reachable!(provider)  # → provider or raises
    module ProviderProbe
      # Connect timeout for Ollama probes (LAN/localhost — fail fast).
      OLLAMA_OPEN_TIMEOUT = 0.5
      # Read timeout for Ollama probes.
      OLLAMA_READ_TIMEOUT = 0.5

      # Connect timeout for OpenAI probes (WAN — allow for latency).
      OPENAI_OPEN_TIMEOUT = 2.0
      # Read timeout for OpenAI probes.
      OPENAI_READ_TIMEOUT = 2.0

      # Probe +provider+ and return it if reachable.
      #
      # Dispatches on the provider's concrete class:
      # - {Woods::Embedding::Provider::Ollama} → +GET /api/tags+ on the
      #   configured host. Any non-5xx response is treated as reachable.
      # - {Woods::Embedding::Provider::OpenAI} → +GET /v1/models+ on
      #   +api.openai.com:443+. A 401 response raises +ProviderUnreachable+
      #   with +reason: "unauthorized"+ because an invalid key means the
      #   provider cannot be used; network failures raise with the appropriate
      #   reason string.
      # - {Woods::Embedding::Provider::Fake} → trivially reachable (#178).
      #   The provider is deterministic and in-process; there is no endpoint
      #   to probe, so the probe succeeds without any network I/O.
      # - Any other object responding to +#embed+ and +#embed_batch+ — an
      #   injected provider object, the third shape
      #   {Woods::Builder#build_embedding_provider} accepts (#178) — is
      #   presumed reachable. An arbitrary host-supplied implementation has
      #   no endpoint contract this probe could exercise, so the probe
      #   succeeds without any network I/O and the provider's first real
      #   call surfaces connectivity or credential errors.
      # - Anything else → raises +ArgumentError+.
      #
      # @param provider [Woods::Embedding::Provider::Ollama,
      #   Woods::Embedding::Provider::OpenAI,
      #   Woods::Embedding::Provider::Fake, Object] a concrete embedding
      #   provider, or an injected object implementing +#embed+/+#embed_batch+
      # @return [Object] the same +provider+ if reachable
      # @raise [Woods::MCP::ProviderUnreachable] if the endpoint is unreachable,
      #   times out, returns 5xx, or (for OpenAI) returns 401
      # @raise [ArgumentError] if +provider+ is neither a recognised provider
      #   class nor an object implementing +#embed+ and +#embed_batch+
      def self.reachable!(provider)
        case provider
        when Woods::Embedding::Provider::Ollama
          probe_ollama!(provider)
        when Woods::Embedding::Provider::OpenAI
          probe_openai!(provider)
        when Woods::Embedding::Provider::Fake
          # In-process, no endpoint: nothing to probe (#178). The case arm
          # is deliberately empty — the method returns +provider+ below.
          nil
        else
          unless provider_object?(provider)
            raise ArgumentError,
                  "#{self}.reachable! does not know how to probe #{provider.class} — " \
                  'the object must implement #embed and #embed_batch, or be a known ' \
                  'provider class (OpenAI, Ollama, Fake)'
          end
          # Injected provider object: presumed reachable (see above). The
          # arm deliberately performs no network I/O — the method returns
          # +provider+ below, like the Fake arm.
          nil
        end
        provider
      end

      # Duck-type check for an injected provider object — the same two-method
      # contract {Woods::Builder#provider_object?} accepts (#178).
      #
      # @param provider [Object]
      # @return [Boolean]
      def self.provider_object?(provider)
        provider.respond_to?(:embed) && provider.respond_to?(:embed_batch)
      end
      private_class_method :provider_object?

      # Probe the Ollama instance backing +provider+.
      #
      # @param provider [Woods::Embedding::Provider::Ollama]
      # @raise [Woods::MCP::ProviderUnreachable]
      # @api private
      def self.probe_ollama!(provider)
        base_url = provider.instance_variable_get(:@host)
        http_get!(base_url, '/api/tags',
                  open_timeout: OLLAMA_OPEN_TIMEOUT,
                  read_timeout: OLLAMA_READ_TIMEOUT,
                  use_ssl: URI.parse(base_url).scheme == 'https') do |response|
          if response.is_a?(Net::HTTPServerError)
            raise Woods::MCP::ProviderUnreachable.new(
              url: base_url,
              reason: 'http_500'
            )
          end
        end
      end
      private_class_method :probe_ollama!

      # Probe the OpenAI API endpoint.
      #
      # The probe sends an unauthenticated +GET /v1/models+ so it deliberately
      # expects a 401 from a healthy OpenAI. Anything that is not a plain 401
      # or 2xx/3xx means the provider cannot be used from this host:
      #
      # - +401 Unauthorized+ → +reason: "unauthorized"+. The expected response
      #   for an unauthed probe; starts :degraded so the first real query
      #   carries the API key and surfaces credential errors precisely.
      # - +403 Forbidden+ → +reason: "forbidden"+. Seen when the edge
      #   intercepts the request before OpenAI's auth layer (geoblock,
      #   corporate proxy). Subsequent embed calls will 403 too, so treating
      #   this as reachable would give operators a false-green status.
      # - +5xx+ → +reason: "http_500"+.
      #
      # @param provider [Woods::Embedding::Provider::OpenAI]
      # @raise [Woods::MCP::ProviderUnreachable]
      # @api private
      def self.probe_openai!(_provider)
        base_url = 'https://api.openai.com'
        http_get!(base_url, '/v1/models',
                  open_timeout: OPENAI_OPEN_TIMEOUT,
                  read_timeout: OPENAI_READ_TIMEOUT,
                  use_ssl: true) do |response|
          reason = openai_unreachable_reason(response)
          next unless reason

          raise Woods::MCP::ProviderUnreachable.new(url: base_url, reason: reason)
        end
      end
      private_class_method :probe_openai!

      # Map an HTTP response from +GET /v1/models+ to a ProviderUnreachable
      # reason string, or nil when the response signals a healthy provider.
      #
      # Uses +is_a?+ (not +case/when+) so RSpec stubs via
      # +allow(response).to receive(:is_a?).with(...)+ compose cleanly —
      # +case/when+ goes through +Module#===+ which some mocks don't round-trip.
      def self.openai_unreachable_reason(response)
        return 'unauthorized' if response.is_a?(Net::HTTPUnauthorized)
        return 'forbidden' if response.is_a?(Net::HTTPForbidden)
        return 'http_500' if response.is_a?(Net::HTTPServerError)

        nil
      end
      private_class_method :openai_unreachable_reason

      # Execute +GET path+ against +base_url+ and yield the response to the
      # caller's block for provider-specific checks.
      #
      # All network-level exceptions are translated into
      # {Woods::MCP::ProviderUnreachable} with a machine-readable reason
      # string before propagating.
      #
      # @param base_url [String] scheme + host + optional port
      # @param path [String] request path
      # @param open_timeout [Numeric]
      # @param read_timeout [Numeric]
      # @param use_ssl [Boolean]
      # @yieldparam response [Net::HTTPResponse]
      # @raise [Woods::MCP::ProviderUnreachable]
      # @api private
      def self.http_get!(base_url, path, open_timeout:, read_timeout:, use_ssl:)
        uri = URI.parse(base_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.use_ssl = use_ssl

        response = http.start { |h| h.get(path) }
        yield response
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        raise Woods::MCP::ProviderUnreachable.new(url: base_url, reason: 'connection_refused')
      rescue Net::OpenTimeout, Errno::ETIMEDOUT, Net::ReadTimeout
        raise Woods::MCP::ProviderUnreachable.new(url: base_url, reason: 'timeout')
      rescue SocketError
        raise Woods::MCP::ProviderUnreachable.new(url: base_url, reason: 'dns_failure')
      end
      private_class_method :http_get!
    end
  end
end
