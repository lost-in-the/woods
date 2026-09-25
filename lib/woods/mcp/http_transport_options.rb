# frozen_string_literal: true

require_relative 'origin_policy'

module Woods
  module MCP
    # Keep the SDK DNS-rebinding guard aligned with Woods' explicit allowlist.
    # Empty configuration retains the SDK's strict loopback defaults.
    module HttpTransportOptions
      def self.for(origins)
        OriginPolicy.new(allowed_origins: origins).transport_options
      end
    end
  end
end
