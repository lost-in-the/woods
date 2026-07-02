# frozen_string_literal: true

require 'time' # Time.httpdate

module Woods
  # Parse an HTTP +Retry-After+ header into a number of seconds to wait.
  #
  # Per RFC 9110 the header is either a non-negative integer count of seconds
  # or an HTTP-date. Calling +.to_f+ on the header directly (the naive
  # approach) turns the HTTP-date form into +0.0+, so a client honoring it
  # would retry immediately and hammer a server that is actively asking it to
  # back off. This helper handles both forms and falls back to a caller-supplied
  # value when the header is absent or unparseable.
  module RetryAfter
    module_function

    # @param header [String, nil] the raw +Retry-After+ header value
    # @param fallback [Numeric] seconds to use when the header is missing or unparseable
    # @param now [Time] reference time for the HTTP-date form (injectable for tests)
    # @return [Float] non-negative seconds to wait
    def seconds(header, fallback:, now: Time.now)
      value = header.to_s.strip
      return fallback.to_f if value.empty?

      # delta-seconds form: a bare non-negative integer.
      return value.to_f if value.match?(/\A\d+\z/)

      # HTTP-date form: wait until that instant, never negative.
      begin
        [Time.httpdate(value) - now, 0.0].max
      rescue ArgumentError
        fallback.to_f
      end
    end
  end
end
