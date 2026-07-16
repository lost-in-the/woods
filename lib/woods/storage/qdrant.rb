# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require 'net/http'
require 'json'
require 'socket'
require 'uri'
require_relative 'vector_store'
require_relative '../util/host_guard'

module Woods
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

        # URL schemes allowed for the Qdrant endpoint. `file://`, `gopher://`,
        # and anything else would let a misconfigured or attacker-controlled
        # config value turn the adapter into an SSRF vector against the host
        # running extraction.
        ALLOWED_SCHEMES = %w[http https].freeze

        # IP ranges that always resolve to loopback, link-local, private, or
        # CGNAT space and should never be contacted as a vector store unless
        # the operator explicitly opts in via `allow_private_hosts: true`.
        #
        # Covers:
        # - IPv4 "this network" / wildcard (0.0.0.0/8)
        # - IPv4 loopback, RFC1918 (10/8, 172.16/12, 192.168/16)
        # - IPv4 link-local 169.254/16 (AWS / Azure / GCP IMDS)
        # - IPv4 CGNAT 100.64/10 (common in managed clouds behind NAT)
        # - IPv6 loopback (::1) and unspecified (::)
        # - IPv6 ULA fc00::/7 (private IPv6 equivalent of RFC1918)
        # - IPv6 link-local fe80::/10
        #
        # NOTE: IPv4-mapped IPv6 (`::ffff:169.254.169.254`) is handled
        # separately in {.private_host?} by detecting the `::ffff:` prefix
        # and extracting the embedded IPv4 portion before range comparison.
        # A blanket `::ffff:0:0/96` range here would (on some Ruby versions,
        # including 3.0) match every IPv4 address due to IPAddr's
        # cross-family auto-mapping in `#include?`.
        PRIVATE_IP_RANGES = [
          '0.0.0.0/8',
          '10.0.0.0/8',
          '127.0.0.0/8',
          '169.254.0.0/16',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '100.64.0.0/10',
          '::/128',
          '::1/128',
          'fc00::/7',
          'fe80::/10'
        ].map { |cidr| IPAddr.new(cidr) }.freeze

        # Hostnames that always map to loopback regardless of DNS.
        PRIVATE_HOSTNAMES = %w[localhost localhost. ip6-localhost ip6-loopback].freeze

        # @param url [String] Qdrant server URL
        # @param collection [String] Collection name
        # @param api_key [String, nil] Optional API key for authentication
        # @param dimensions [Integer, nil] Expected vector dimension. When set,
        #   {#store_batch}/{#store} pre-validate every vector's length before
        #   sending the HTTP request — Qdrant returns a 400 on mismatch, but
        #   detecting it client-side avoids wasted network round-trips and
        #   keeps error shape consistent with the pgvector adapter.
        # @param allow_private_hosts [Boolean] Explicitly permit a URL whose
        #   host resolves inside loopback, link-local, or RFC1918 space. Off
        #   by default to block the common SSRF footgun. Set to true when the
        #   operator intentionally runs Qdrant on `localhost:6333` or inside
        #   a private network.
        def initialize(url:, collection:, api_key: nil, dimensions: nil, allow_private_hosts: false)
          @uri = self.class.validate_url!(url, allow_private_hosts: allow_private_hosts)
          @url = url
          @collection = collection
          @api_key = api_key
          @dimensions = dimensions
        end

        # Validate a Qdrant endpoint URL — scheme in {ALLOWED_SCHEMES} and,
        # unless opted out, host outside loopback / link-local / RFC1918.
        # Public so callers can pre-check configuration before constructing.
        def self.validate_url!(url, allow_private_hosts: false)
          uri = URI(url)
          validate_scheme!(uri)
          validate_host_present!(uri, url)
          validate_host_visibility!(uri.host.to_s, allow_private_hosts: allow_private_hosts)
          uri
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Qdrant URL is not a valid URI: #{e.message}"
        end

        def self.validate_scheme!(uri)
          return if ALLOWED_SCHEMES.include?(uri.scheme)

          raise ArgumentError,
                "Qdrant URL scheme must be one of #{ALLOWED_SCHEMES.join(', ')}; got #{uri.scheme.inspect}"
        end

        def self.validate_host_present!(uri, url)
          return unless uri.host.nil? || uri.host.empty?

          raise ArgumentError, "Qdrant URL must include a host: #{url.inspect}"
        end

        def self.validate_host_visibility!(host, allow_private_hosts:)
          return if allow_private_hosts

          # Canonicalize (strip port, trailing dot, IPv6 brackets) via
          # the shared helper so Qdrant and OriginGuard stay in sync.
          canonical = Util::HostGuard.canonicalize(host)

          # Non-canonical numeric hosts (hex `0x7f000001`, octal
          # `0177.0.0.1`, bare integer `2130706433`, short-form `127.1`,
          # mixed-radix `0x7f.0.0.1`) are accepted by URI and getaddrinfo
          # but NOT by `IPAddr`, so the private-range check silently
          # passed them through. Reject any host that looks numeric-but-
          # not-standard instead of trying to canonicalize every form.
          if Util::HostGuard.suspicious_numeric_host?(canonical)
            raise ArgumentError,
                  "Qdrant URL uses a non-standard numeric host (#{host}). " \
                  'Hex/octal/integer/short-form IPs are rejected because they ' \
                  'can disguise loopback or private addresses. Pass the ' \
                  'dotted-decimal form explicitly.'
          end

          return unless private_host?(canonical)

          raise ArgumentError,
                "Qdrant URL targets a private/loopback host (#{host}); " \
                'pass allow_private_hosts: true to permit. ' \
                'Note: validation is at config time; DNS resolution happens ' \
                'per request, so a public hostname that later resolves to a ' \
                'private IP is NOT caught here — deploy Qdrant on a trusted network.'
        end

        def self.private_host?(host)
          return true if PRIVATE_HOSTNAMES.include?(host)

          ip = unmap_ipv4(IPAddr.new(host))

          # Restrict range-check to the SAME address family so IPAddr's
          # cross-family `include?` can't silently match all IPv4
          # addresses into an IPv6 range (or vice versa) — a quirk
          # observed on Ruby 3.0's IPAddr that trapped legitimate public
          # IPv4 addresses as "IPv4-mapped private" when the range list
          # contained `::ffff:0:0/96`.
          PRIVATE_IP_RANGES.any? do |range|
            range.family == ip.family && range.include?(ip)
          end
        rescue IPAddr::InvalidAddressError
          false
        end

        # IPv4-mapped IPv6 (`::ffff:169.254.169.254`): extract the
        # embedded IPv4 (low 32 bits) before range comparison so the AWS
        # IMDS address is caught by 169.254/16 even when disguised as
        # IPv4-mapped IPv6. Returns the input unchanged for every other
        # address.
        def self.unmap_ipv4(ip)
          return ip unless ip.ipv6?
          return ip unless ip.to_string.start_with?('0000:0000:0000:0000:0000:ffff:')

          mapped_ipv4 = ip.to_i & 0xffff_ffff
          return ip unless mapped_ipv4.positive?

          IPAddr.new(mapped_ipv4, Socket::AF_INET)
        end

        private_class_method :validate_scheme!, :validate_host_present!,
                             :validate_host_visibility!, :private_host?, :unmap_ipv4

        # Create the collection if it doesn't exist.
        #
        # @param dimensions [Integer] Vector dimensionality
        def ensure_collection!(dimensions:)
          @dimensions ||= dimensions
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
        # Payload key carrying the original Woods unit identifier. Qdrant
        # only accepts unsigned integers or UUIDs as point IDs — sending raw
        # identifiers ("Api::V1::UsersController") made every upsert 400 on
        # a real server (specs stub Net::HTTP, so they never noticed). The
        # point ID is a deterministic UUID derived from the identifier and
        # the identifier itself round-trips through the payload.
        WOODS_ID_KEY = '_woods_identifier'

        def store(id, vector, metadata = {})
          validate_dimensions!(vector) if @dimensions
          body = {
            points: [
              {
                id: point_id_for(id),
                vector: vector,
                payload: (metadata || {}).merge(WOODS_ID_KEY => id.to_s)
              }
            ]
          }
          request(:put, "/collections/#{@collection}/points", body)
        end

        # Store multiple vectors in a single batch upsert request.
        #
        # Sends the entire entries array in one HTTP call. Callers are responsible
        # for chunking into reasonable batch sizes (e.g., 100–500 points) before
        # calling this method; the embedding Indexer's +batch_size+ config controls
        # the upstream chunk size.
        #
        # @param entries [Array<Hash>] Each entry has :id, :vector, :metadata keys
        # @raise [Woods::Error] if any entry's vector doesn't match the configured
        #   dimension. Validation runs before the HTTP request so partial-batch
        #   state is impossible on dimension mismatch.
        def store_batch(entries)
          return if entries.empty?

          if @dimensions
            entries.each_with_index do |entry, idx|
              validate_dimensions!(entry[:vector], index: idx)
            end
          end

          body = {
            points: entries.map do |entry|
              {
                id: point_id_for(entry[:id]),
                vector: entry[:vector],
                payload: (entry[:metadata] || {}).merge(WOODS_ID_KEY => entry[:id].to_s)
              }
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
            payload = hit['payload'] || {}
            SearchResult.new(
              # Map the UUID point back to the Woods identifier the rest of
              # the pipeline keys on (falls back to the raw point id for
              # collections written before WOODS_ID_KEY existed).
              id: payload[WOODS_ID_KEY] || hit['id'],
              score: hit['score'],
              metadata: payload
            )
          end
        end

        # @see Interface#delete
        def delete(id)
          body = { points: [point_id_for(id)] }
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

        # Deterministic UUID for a Woods identifier — Qdrant's point-ID
        # grammar accepts only unsigned integers or UUIDs. SHA-256 of the
        # identifier, formatted 8-4-4-4-12 with the version nibble forced to
        # 5 and the variant to RFC 4122, so the same unit always maps to the
        # same point (upserts overwrite instead of duplicating).
        #
        # @param id [String, #to_s] Woods unit identifier
        # @return [String] UUID-formatted point ID
        def point_id_for(id)
          hex = Digest::SHA256.hexdigest(id.to_s)
          format(
            '%<a>s-%<b>s-5%<c>s-%<d>s%<e>s-%<f>s',
            a: hex[0, 8], b: hex[8, 4], c: hex[13, 3],
            d: %w[8 9 a b][hex[16].to_i(16) % 4], e: hex[17, 3], f: hex[20, 12]
          )
        end

        # Cap interpolated response bodies so misconfigured Qdrant responses
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

        # Ensure the provided vector matches the store's configured dimension.
        #
        # @param vector [Array<Numeric>]
        # @param index [Integer, nil] position in the batch
        # @raise [Woods::Error] on dimension mismatch
        def validate_dimensions!(vector, index: nil)
          return if vector.respond_to?(:length) && vector.length == @dimensions

          where = index ? " (entry #{index})" : ''
          got = vector.respond_to?(:length) ? vector.length : vector.class
          raise Woods::Error,
                "Vector dimension mismatch#{where}: got #{got}, expected #{@dimensions}"
        end

        # Build a Qdrant filter from metadata key-value pairs.
        #
        # @param filters [Hash] Metadata filters
        # @return [Hash] Qdrant-compatible filter with must conditions
        def build_filter(filters)
          conditions = filters.map do |key, value|
            if value.is_a?(Array)
              { key: key.to_s, match: { any: value } }
            else
              { key: key.to_s, match: { value: value } }
            end
          end
          { must: conditions }
        end

        # Send an HTTP request to the Qdrant API.
        #
        # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
        # @param path [String] API path
        # @param body [Hash, nil] Request body
        # @return [Hash] Parsed JSON response
        # @raise [Woods::Error] if the API returns a non-success status
        def request(method, path, body = nil)
          req = build_request(method, path, body)
          response = http_client.request(req)

          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "Qdrant API error: #{response.code} #{truncate_response_body(response.body)}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNRESET, Net::OpenTimeout, IOError
          # Connection dropped — reset and retry once
          @http_client = nil
          response = http_client.request(req)
          unless response.is_a?(Net::HTTPSuccess)
            raise Woods::Error, "Qdrant API error: #{response.code} #{truncate_response_body(response.body)}"
          end

          JSON.parse(response.body)
        end

        # Return a reusable, started HTTP client for the Qdrant server.
        # Calling http.start opens a persistent TCP connection so
        # keep_alive_timeout actually takes effect across requests.
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
