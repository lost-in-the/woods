# frozen_string_literal: true

require 'uri'
require_relative '../util/host_guard'

module Woods
  module MCP
    # One immutable policy for the outer Rack guard and the legacy MCP SDK.
    # Keep SDK rebinding protection active and pass original request headers.
    class OriginPolicy
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
      DEFAULT_ORIGINS = %w[
        http://localhost http://127.0.0.1 http://[::1]
        https://localhost https://127.0.0.1 https://[::1]
      ].freeze

      attr_reader :transport_options

      def initialize(allowed_origins: nil)
        entries = Array(allowed_origins).compact.reject do |entry|
          entry.to_s.valid_encoding? && entry.to_s.strip.empty?
        end
        @explicit = entries.map { |entry| configured_origin(entry) }.uniq.freeze
        @allowed = @explicit.empty? ? DEFAULT_ORIGINS : @explicit
        @hosts = @explicit.map do |origin|
          host = authority(origin)
          (host.end_with?(']') ? host[1...-1] : host).freeze
        end.uniq.freeze
        @transport_options = if @explicit.empty?
                               {}.freeze
                             else
                               { allowed_origins: transport_origins, allowed_hosts: @hosts }.freeze
                             end
        freeze
      end

      def host_allowed?(host)
        return true if host.nil?
        return false unless host.is_a?(String) && host.valid_encoding?

        parsed = parsed_origin("http://#{host}")
        return false unless parsed

        hostname = parsed.hostname.downcase
        return false if Util::HostGuard.suspicious_numeric_host?(hostname)
        return true if LOOPBACK_HOSTS.include?(hostname)

        @hosts.include?(host.downcase) || @hosts.include?(hostname)
      end

      def origin_allowed?(origin, host:)
        return true if origin.nil?
        return false unless parsed_origin(origin)

        normalized = normalized_origin(origin)
        return true if @explicit.include?(normalized)
        return false unless @allowed.include?(normalized) || @allowed.include?(normalized.sub(/:\d+\z/, ''))
        return false unless host.is_a?(String) && host.valid_encoding?

        default_port = normalized.start_with?('https://') ? ':443' : ':80'
        authority(normalized).delete_suffix(default_port) == host.downcase.delete_suffix(default_port)
      end

      private

      def configured_origin(entry)
        raw = entry.to_s
        value = raw.strip.downcase.delete_suffix('/') if raw.valid_encoding?
        unless parsed_origin(value)
          label = raw.b.byteslice(0, 160).inspect
          raise ArgumentError, "Invalid MCP allowed origin #{label}: expected http(s)://host[:port] without a path"
        end

        normalized_origin(value).freeze
      end

      def normalized_origin(origin)
        value = origin.downcase
        value.delete_suffix(value.start_with?('https://') ? ':443' : ':80')
      end

      # SDK 0.23 and 0.25 compare explicit entries literally. Both default-port
      # spellings are needed for cross-origin requests; same-authority matching
      # is otherwise performed independently by both layers.
      def transport_origins
        @explicit.flat_map do |origin|
          parsed = parsed_origin(origin)
          port = parsed.scheme == 'https' ? 443 : 80
          parsed.port == port ? [origin, "#{origin}:#{port}"] : [origin]
        end.uniq.map(&:freeze).freeze
      end

      def authority(origin)
        origin.sub(%r{\Ahttps?://}, '')
      end

      def parsed_origin(origin)
        return unless origin.is_a?(String) && !origin.match?(/[[:space:][:cntrl:]]/)

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
