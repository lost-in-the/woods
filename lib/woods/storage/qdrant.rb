# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
require 'json'
require 'openssl'
require 'socket'
require 'uri'
require_relative 'vector_store'
require_relative '../util/host_guard'
require_relative '../util/uuid5'

module Woods
  # Same conditional-define pattern used elsewhere in the gem (pgvector,
  # metadata_store) so this file can be required in isolation without
  # tripping NameError on the RequestError superclass below.
  class Error < StandardError; end unless defined?(Woods::Error)

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

        class RequestError < Woods::Error
          attr_reader :http_status, :retry_after

          def initialize(message, http_status: nil, retry_after: nil, retryable: false, ambiguous: false)
            super(message)
            @http_status = http_status
            @retry_after = retry_after
            @retryable = retryable
            @ambiguous = ambiguous
          end

          def retryable?
            @retryable
          end

          def ambiguous?
            @ambiguous
          end
        end

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

        # Fixed UUIDv5 namespace for Woods → Qdrant point ids.
        #
        # Qdrant only accepts an unsigned integer or a UUID as a point id;
        # a Woods identifier ("User", "Api::V1::UsersController",
        # "User#chunk_0") is neither, and sending one back is a 400 on
        # every upsert. Point ids are therefore UUIDv5 values derived from
        # the identifier, with the identifier itself carried in the payload
        # under {IDENTIFIER_KEY} so search and delete can round-trip.
        #
        # Derived once as
        #   Util::UUID5.generate(Util::UUID5::NAMESPACE_DNS, 'woods.qdrant.point-id')
        # and pinned as a literal here. `spec/util/uuid5_spec.rb` asserts
        # the literal still equals that derivation.
        #
        # **This value must never change.** The whole point of a v5 id is
        # that re-embedding an unchanged unit lands on the same point and
        # *replaces* it. A new namespace makes every existing point
        # unreachable — orphaned vectors that no delete can name and a
        # silently doubled collection.
        POINT_ID_NAMESPACE = '7eb8ae2b-670b-55ee-a474-36bd1a8dc6b4'

        # Query string appended to every mutating point operation.
        #
        # Qdrant defaults these endpoints to `wait=false`: the API returns
        # `status: "acknowledged"` as soon as the change is queued, before it is
        # readable. Every caller in this gem assumes otherwise — the embed
        # pipeline writes vectors and then dumps/verifies, and the prune paths
        # delete and then re-count — so an un-awaited mutation reads back as
        # stale data (a deleted unit still answering searches, a fresh count
        # showing the pre-write total). Correctness beats the throughput the
        # async default buys.
        WAIT_FOR_WRITE = '?wait=true'

        # Points per page when scrolling ids in {#each_id}. Large enough that a
        # sizable index costs few round trips, small enough that one response
        # stays comfortably in memory (ids and one payload key only).
        SCROLL_PAGE_SIZE = 1_000
        DISTANCES = %w[Cosine Dot Euclid Manhattan].freeze

        # Payload key holding the original Woods identifier for a point.
        #
        # Deliberately NOT `identifier`: the embedding Indexer already
        # writes an `identifier` key holding the unit's *base* identifier,
        # while a point id is derived from the possibly chunk-suffixed
        # embed id ("User#chunk_0"). Reusing the key would clobber one
        # with the other.
        IDENTIFIER_KEY = 'woods_identifier'

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
        def initialize(url:, collection:, api_key: nil, dimensions: nil, distance: 'Cosine', allow_private_hosts: false) # rubocop:disable Metrics/ParameterLists
          @uri = self.class.validate_url!(url, allow_private_hosts: allow_private_hosts)
          @url = url
          @collection = collection
          @api_key = api_key
          @dimensions = dimensions
          @distance = normalize_distance(distance)
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
          dimensions = normalize_dimensions(dimensions)
          validate_configured_dimensions!(dimensions)
          @dimensions = dimensions
          existing = request(:get, "/collections/#{@collection}")
          verify_collection_dimensions!(existing, dimensions)
          true
        rescue RequestError => e
          raise unless e.http_status == 404

          create_collection!(dimensions)
          true
        end

        # Deterministic Qdrant point id for a Woods identifier.
        #
        # Integers and canonical UUIDs pass through untouched — those are
        # already native Qdrant point ids, so a caller holding one (from a
        # raw scroll, say) can address the point directly. Everything else
        # is a Woods identifier and becomes its UUIDv5.
        #
        # @param identifier [String, Integer]
        # @return [String, Integer]
        def self.point_id(identifier)
          return identifier if identifier.is_a?(Integer)
          return identifier if Util::UUID5.uuid?(identifier)

          Util::UUID5.generate(POINT_ID_NAMESPACE, identifier)
        end

        # Store or update a vector with metadata payload.
        #
        # The point id sent to Qdrant is {.point_id}(id), not +id+ itself;
        # the original identifier travels in the payload under
        # {IDENTIFIER_KEY} so {#search} can map results back.
        #
        # @param id [String] Unique identifier
        # @param vector [Array<Float>] The embedding vector
        # @param metadata [Hash] Optional payload metadata
        # @see Interface#store
        def store(id, vector, metadata = {})
          validate_dimensions!(vector) if @dimensions
          body = { points: [build_point(id, vector, metadata)] }
          request(:put, "/collections/#{@collection}/points#{WAIT_FOR_WRITE}", body)
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
            points: entries.map { |entry| build_point(entry[:id], entry[:vector], entry[:metadata] || {}) }
          }
          request(:put, "/collections/#{@collection}/points#{WAIT_FOR_WRITE}", body)
        end

        # Search for similar vectors.
        #
        # The query vector is dimension-checked before the request, mirroring
        # the upsert path: otherwise a wrong-dimension query surfaces as a
        # Qdrant 400 instead of the typed Woods::Error callers already handle
        # from {#store}/{#store_batch}.
        #
        # @param query_vector [Array<Float>] The query embedding
        # @param limit [Integer] Maximum results to return
        # @param filters [Hash] Metadata key-value filters
        # @return [Array<SearchResult>] Results sorted by descending similarity,
        #   with +id+ carrying the Woods identifier (not the UUID point id)
        #   so the adapter is interchangeable with pgvector downstream.
        # @raise [Woods::Error] if the query vector's length disagrees with the
        #   configured dimension
        # @see Interface#search
        def search(query_vector, limit: 10, filters: {})
          validate_dimensions!(query_vector) if @dimensions
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
              # Reverse-map the UUID point id back to the Woods identifier.
              # Falls back to the raw point id for points written by
              # something other than this adapter (or before the UUID
              # mapping existed) — a hit with no reverse mapping is still
              # more useful than nil.
              id: payload[IDENTIFIER_KEY] || hit['id'],
              score: hit['score'],
              metadata: payload
            )
          end
        end

        # The vector width the collection was actually created with.
        #
        # `ensure_collection!` is a PUT that Qdrant treats as idempotent, so an
        # existing collection keeps whatever width it was built with; a
        # dimension change then surfaces as a 400 on every upsert. Reading it
        # back lets the pipeline refuse up front with a re-index remedy (#214).
        #
        # @return [Integer, nil] the collection's vector size, or nil when the
        #   collection does not exist or the shape is unrecognized (named
        #   vectors, for instance, which this adapter does not write)
        def stored_dimensions
          extract_dimensions(request(:get, "/collections/#{@collection}"))
        rescue RequestError => e
          raise unless e.http_status == 404

          nil
        end

        # Iterate over every stored id, yielding the Woods identifier.
        #
        # Uses the scroll API with `with_vector: false` and only the identifier
        # key requested, so reconciliation costs payload-sized pages rather
        # than whole vectors. Yields the same value {#search} returns as `id`
        # (the Woods identifier, reverse-mapped from the payload) so callers
        # can compare against extraction output directly, and so any id yielded
        # here can be handed straight back to {#delete}.
        #
        # Points written by something else — no {IDENTIFIER_KEY} in their
        # payload — are **skipped**, not yielded (STO-2). A collection may be
        # shared with another writer; an unattributable point can never appear
        # in extraction output, so yielding it would make the embed pipeline's
        # reconciliation sweep read it as a vanished unit and delete another
        # system's vector on every run. Enumerating only what Woods wrote is
        # the property callers depend on. {#search} still falls back to the raw
        # id, because there the point was matched, not swept.
        #
        # @see Interface#each_id
        def each_id(&block)
          return enum_for(:each_id) unless block

          offset = nil
          loop do
            points, offset = scroll_page(offset)
            points.each do |point|
              identifier = woods_identifier_for(point)
              yield(identifier) if identifier
            end
            break if offset.nil?
          end
        end

        # Delete a single point by Woods identifier.
        #
        # Translates through {.point_id}, so it necessarily computes the
        # same id {#store}/{#store_batch} wrote. Deleting by the raw Woods
        # string would 400 (or, worse, succeed against nothing) and leave
        # the vector live — silent data retention.
        #
        # @see Interface#delete
        def delete(id)
          body = { points: [self.class.point_id(id)] }
          request(:post, "/collections/#{@collection}/points/delete#{WAIT_FOR_WRITE}", body)
        end

        # @see Interface#delete_by_filter
        def delete_by_filter(filters)
          body = { filter: build_filter(filters) }
          request(:post, "/collections/#{@collection}/points/delete#{WAIT_FOR_WRITE}", body)
        end

        # @see Interface#count
        def count
          response = request(:post, "/collections/#{@collection}/points/count", { exact: true })
          response['result']['count']
        end

        private

        def normalize_dimensions(value)
          dimensions = Integer(value)
          raise ArgumentError, 'dimensions must be positive' unless dimensions.positive?

          dimensions
        end

        def normalize_distance(value)
          distance = DISTANCES.find { |candidate| candidate.casecmp?(value.to_s) }
          return distance if distance

          raise ArgumentError, "distance must be one of #{DISTANCES.join(', ')}"
        end

        def validate_configured_dimensions!(dimensions)
          return unless @dimensions && Integer(@dimensions) != dimensions

          raise Woods::ConfigurationError,
                "Qdrant dimension mismatch: Builder requested #{dimensions}, " \
                "but vector_store_options configured #{@dimensions}"
        end

        def verify_collection_dimensions!(response, dimensions)
          vectors = response.dig('result', 'config', 'params', 'vectors')
          unless vectors.is_a?(Hash) && vectors['size']
            raise Woods::ConfigurationError,
                  "Qdrant collection #{@collection.inspect} uses named vectors; named vectors are not supported " \
                  'by this unnamed-vector adapter.'
          end
          existing_dimensions = vectors['size']
          if existing_dimensions != dimensions
            raise Woods::ConfigurationError,
                  "Qdrant collection dimension mismatch: configured #{dimensions}, existing #{existing_dimensions}. " \
                  'Use a new collection or rebuild the existing collection.'
          end
          return if vectors['distance'] == @distance

          raise Woods::ConfigurationError,
                "Qdrant collection distance mismatch: configured #{@distance}, existing #{vectors['distance']}. " \
                'Use a new collection or rebuild the existing collection.'
        end

        def create_collection!(dimensions)
          request(
            :put,
            "/collections/#{@collection}",
            vectors: { size: dimensions, distance: @distance }
          )
        end

        def extract_dimensions(response)
          config = response.dig('result', 'config', 'params', 'vectors')
          return unless config.is_a?(Hash)

          size = config['size']
          size if size.is_a?(Integer) && size.positive?
        end

        # Fetch one page of the scroll cursor.
        #
        # @param offset [Object, nil] the cursor from the previous page
        # @return [Array(Array<Hash>, Object)] the page's points and the next
        #   offset (nil when the scroll is exhausted)
        def scroll_page(offset)
          body = { limit: SCROLL_PAGE_SIZE, with_payload: [IDENTIFIER_KEY], with_vector: false }
          body[:offset] = offset if offset

          result = request(:post, "/collections/#{@collection}/points/scroll", body)['result'] || {}
          [result['points'] || [], result['next_page_offset']]
        end

        # The Woods identifier a scrolled point carries, or nil when the point
        # was not written by this adapter.
        #
        # @param point [Hash] a scroll-result point
        # @return [String, nil]
        def woods_identifier_for(point)
          (point['payload'] || {})[IDENTIFIER_KEY]
        end

        # Build one Qdrant point: UUIDv5 id, vector, and a payload carrying
        # the original Woods identifier alongside the caller's metadata.
        #
        # The identifier is merged in rather than replacing the payload, and
        # written last so a metadata hash that already carries the key can't
        # break the reverse mapping. Symbol and string metadata keys both
        # serialize to JSON strings, so the string key here is what Qdrant
        # stores either way.
        #
        # @param id [String, Integer] Woods identifier (or native point id)
        # @param vector [Array<Float>]
        # @param metadata [Hash]
        # @return [Hash]
        def build_point(id, vector, metadata)
          { id: self.class.point_id(id),
            vector: vector,
            payload: (metadata || {}).merge(IDENTIFIER_KEY => id) }
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
          attempt = 0

          begin
            attempt += 1
            response = http_client.request(req)
            parse_response(response, path)
          rescue OpenSSL::SSL::SSLError => e
            discard_http_client
            raise RequestError, "Qdrant TLS error: #{e.message}"
          rescue Errno::ECONNREFUSED, SocketError, Net::OpenTimeout => e
            discard_http_client
            retry if attempt == 1

            raise transport_error(e, ambiguous: false)
          rescue Errno::ECONNRESET, Net::ReadTimeout, Net::WriteTimeout, IOError => e
            discard_http_client
            retry if attempt == 1 && !write_request?(method, path)

            raise transport_error(e, ambiguous: write_request?(method, path))
          end
        end

        def parse_response(response, path)
          raise response_error(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise RequestError.new(
            "Qdrant API returned malformed JSON for #{path}: #{e.message}",
            http_status: response.code.to_i
          )
        end

        def response_error(response)
          status = response.code.to_i
          RequestError.new(
            "Qdrant API error: #{status} #{truncate_response_body(response.body)}",
            http_status: status,
            retry_after: response['Retry-After'],
            retryable: status == 408 || status == 429 || status >= 500
          )
        end

        def transport_error(error, ambiguous:)
          RequestError.new(
            "Qdrant transport error: #{error.class}: #{error.message}",
            retryable: true,
            ambiguous: ambiguous
          )
        end

        # Only GET and read-only POST (search/count/scroll) retry a
        # mid-exchange network failure — every other verb, and every other
        # POST (upsert, delete), may already have committed server-side, so
        # a blind retry risks double-applying it.
        def write_request?(method, path)
          return false if method == :get
          return false if method == :post && read_only_post?(path)

          true
        end

        def read_only_post?(path)
          %w[/search /count /scroll].any? { |suffix| path.split('?').first.end_with?(suffix) }
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
