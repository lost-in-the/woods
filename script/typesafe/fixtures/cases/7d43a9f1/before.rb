# frozen_string_literal: true

require 'digest'
require 'json'

module FixtureCache
  DOMAINS = %i[search metadata].freeze

  def self.cache_key(domain, *parts)
    raise ArgumentError, 'unsupported cache domain' unless DOMAINS.include?(domain)

    raw = JSON.generate(parts.map(&:to_s))
    suffix = raw.length > 64 ? Digest::SHA256.hexdigest(raw) : raw
    "woods:cache:#{domain}:#{suffix}"
  end
end
