# frozen_string_literal: true

require 'uri'
require_relative '../util/host_guard'

module Woods
  module MCP
    # Immutable HTTP policy shared by Woods preflight and the MCP transport.
    # Explicit cross-origin entries normalize HTTP(S) default ports. A portless entry also permits
    # same-authority requests on another port, which the SDK accepts natively.
    # No request header is rewritten and SDK rebinding protection stays enabled.
    class OriginPolicy
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
      DEFAULT_ORIGINS = %w[
        http://localhost http://127.0.0.1 http://[::1]
        https://localhost https://127.0.0.1 https://[::1]
      ].freeze

      # @param allowed_origins [Array<String>, nil] Explicit browser origins
      def initialize(allowed_origins: nil)
        entries = Array(allowed_origins).compact.reject do |entry|
          entry.to_s.valid_encoding? && entry.to_s.strip.empty?
        end
        @explicit_origins = entries.map { |entry| configured_origin(entry) }.uniq.freeze
        @allowed = (@explicit_origins.empty? ? DEFAULT_ORIGINS : @explicit_origins).freeze
        @allowed_hosts = @explicit_origins.map do |origin|
          host = authority(origin)
          # SDK bare IPv6 host entries omit brackets; host:port entries retain
          # them. URI#host alone retains brackets and loses explicit ports.
          (host.end_with?(']') ? host[1...-1] : host).freeze
        end.uniq.freeze
        @transport_options = { allowed_origins: transport_origins, allowed_hosts: @allowed_hosts }.freeze
        freeze
      end

      # @return [Hash] Constructor options supported by the MCP SDK
      attr_reader :transport_options

      # @param host [String, nil] Unmodified HTTP Host header
      # @return [Boolean] Whether the request authority is allowed
      def host_allowed?(host)
        return true if host.nil?
        return false unless host.is_a?(String) && host.valid_encoding?

        parsed = parsed_origin("http://#{host}")
        return false unless parsed

        hostname = parsed.hostname.downcase
        return false if Util::HostGuard.suspicious_numeric_host?(hostname)
        return true if LOOPBACK_HOSTS.include?(hostname)

        @allowed_hosts.include?(host.downcase) || @allowed_hosts.include?(hostname)
      end

      # @param origin [String, nil] Unmodified HTTP Origin header
      # @param host [String, nil] Unmodified HTTP Host header
      # @return [Boolean] Whether preflight and SDK dispatch can both accept it
      def origin_allowed?(origin, host:)
        return true if origin.nil?
        return false unless parsed_origin(origin)

        normalized = normalized_origin(origin)
        return true if @explicit_origins.include?(normalized)
        return false unless @allowed.include?(normalized) || @allowed.include?(normalized.sub(/:\d+\z/, ''))
        return false unless host.is_a?(String) && host.valid_encoding?

        # Matches the SDK's same-authority rule. The origin's scheme selects
        # its default port; request.scheme is unreliable behind reverse proxies.
        default_port = normalized.start_with?('https://') ? ':443' : ':80'
        authority(normalized).delete_suffix(default_port) == host.downcase.delete_suffix(default_port)
      end

      private

      def configured_origin(entry)
        raw = entry.to_s
        normalized = raw.downcase.sub(%r{/\z}, '') if raw.valid_encoding?
        unless parsed_origin(normalized)
          label = raw.b.byteslice(0, 160).inspect
          raise ArgumentError, "Invalid MCP allowed origin #{label}: expected http(s)://host[:port] without a path"
        end

        normalized_origin(normalized).freeze
      end

      def normalized_origin(origin)
        value = origin.downcase
        value.delete_suffix(value.start_with?('https://') ? ':443' : ':80')
      end

      # The SDK compares configured origins literally. Include equivalent
      # default-port spellings without rewriting the incoming request headers.
      def transport_origins
        @explicit_origins.flat_map do |origin|
          parsed = parsed_origin(origin)
          default = parsed.scheme == 'https' ? 443 : 80
          parsed.port == default ? [origin, "#{origin}:#{default}"] : [origin]
        end.uniq.map(&:freeze).freeze
      end

      def authority(origin)
        origin.sub(%r{\Ahttps?://}, '')
      end

      # Parse only serialized HTTP origins, never URLs with paths, userinfo,
      # query strings, fragments or whitespace. The comparison layer handles
      # default-port equivalence separately from parsing.
      def parsed_origin(origin)
        return unless origin.is_a?(String) && origin.valid_encoding? && origin.ascii_only?
        return if origin.match?(/[[:space:][:cntrl:]]/)

        parsed = URI.parse(origin)
        return unless %w[http https].include?(parsed.scheme&.downcase)
        return unless parsed.host && !parsed.host.empty?
        return unless parsed.path.to_s.empty? && !parsed.userinfo && !parsed.query && !parsed.fragment
        return unless parsed.port&.between?(1, 65_535)

        parsed
      rescue URI::InvalidURIError, ArgumentError
        nil
      end
    end
  end
end
