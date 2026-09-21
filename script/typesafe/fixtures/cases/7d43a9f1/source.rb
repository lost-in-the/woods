# frozen_string_literal: true

require 'digest'

module FixtureCache
  DOMAINS = %i[search metadata].freeze

  def self.cache_key(domain, *parts)
    raise ArgumentError, 'unsupported cache domain' unless DOMAINS.include?(domain)

    raw = if parts.one?
            parts.first.to_s
          else
            parts.map { |part| "#{part.to_s.bytesize}:#{part}" }.join
          end
    suffix = raw.length > 64 ? Digest::SHA256.hexdigest(raw) : raw
    "woods:cache:#{domain}:#{suffix}"
  end
end
