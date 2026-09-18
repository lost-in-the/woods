# frozen_string_literal: true

require 'uri'

module Woods
  module MCP
    # Keep the SDK DNS-rebinding guard aligned with Woods' explicit allowlist.
    # Empty configuration retains the SDK's strict loopback defaults.
    module HttpTransportOptions
      def self.for(origins)
        normalized = Array(origins).map { |origin| origin.strip.downcase.delete_suffix('/') }.reject(&:empty?)
        return {} if normalized.empty?

        hosts = normalized.filter_map do |origin|
          uri = URI.parse(origin)
          uri.host if %w[http https].include?(uri.scheme)
        rescue URI::InvalidURIError
          nil
        end
        { allowed_origins: normalized, allowed_hosts: hosts.uniq }
      end
    end
  end
end
