# frozen_string_literal: true

require 'digest'

module FixtureCache
  DOMAINS = %i[search metadata].freeze

  def self.cache_key(domain, *parts)
    raise ArgumentError, 'unsupported cache domain' unless DOMAINS.include?(domain)

    raw = parts.map do |part|
      value = part.to_s
      "#{value.bytesize}:#{value}"
    end.join
    suffix = raw.length > 64 ? Digest::SHA256.hexdigest(raw) : raw
    "woods:cache:#{domain}:#{suffix}"
  end
end
