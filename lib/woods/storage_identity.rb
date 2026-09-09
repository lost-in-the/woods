# frozen_string_literal: true

require 'base64'
require 'json'

module Woods
  # Internal storage keys; public unit identifiers remain unchanged.
  module StorageIdentity
    PREFIX = '@woods-unit:'

    def self.key(identifier, type)
      PREFIX + Base64.urlsafe_encode64(JSON.generate([identifier.to_s, type.to_s]), padding: false)
    end

    def self.parts(key)
      return unless key.to_s.start_with?(PREFIX)

      value = JSON.parse(Base64.urlsafe_decode64(key.delete_prefix(PREFIX)))
      value if value.is_a?(Array) && value.size == 2 && value.all?(String)
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def self.identifier(key)
      parts(key)&.first || key
    end
  end
end
