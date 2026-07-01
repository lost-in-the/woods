# frozen_string_literal: true

module Woods
  module Util
    # Shared host-header / URL-host canonicalization used by {MCP::OriginGuard}
    # and the {Storage::VectorStore::Qdrant} URL validator.
    #
    # Both components need to reject numeric IPv4 notations that `URI` and
    # `getaddrinfo` accept but `IPAddr` does not — hex (`0x7f000001`),
    # bare integer (`2130706433`), octal (`017700000001` or
    # `0177.0.0.1`), short-form (`127.1`), mixed-radix (`0x7f.0.0.1`).
    # Keeping the logic in one place prevents drift between the two
    # defenses (which previously had slightly different regex lists).
    module HostGuard
      # Non-canonical numeric IPv4 forms that legitimate clients never
      # emit but `getaddrinfo` will happily resolve — rejecting the form
      # is safer than trying to intuit the intended IPv4.
      NUMERIC_HOST_BYPASS = Regexp.union(
        /\A0x[0-9a-f]+\z/,           # hex: `0x7f000001`
        /\A\d+\z/,                   # bare integer: `2130706433`
        /\A0[0-7]+\z/,               # bare octal: `017700000001`
        /\A\d+\.\d+\z/,              # short-form two-part: `127.1`
        /\A\d+\.\d+\.\d+\z/          # short-form three-part: `127.0.1`
      ).freeze

      # Octets inside a four-part dotted form that tag the form as
      # non-canonical: leading zero (octal interpretation), or `0x`
      # prefix (hex interpretation).
      SUSPICIOUS_OCTET = Regexp.union(
        /\A0\d+\z/,                  # leading-zero octal: `0177`
        /\A0x[0-9a-f]+\z/            # hex octet: `0x7f`
      ).freeze

      module_function

      # Canonicalize a host string: downcase, strip port, strip the
      # FQDN trailing dot, drop IPv6 brackets. Returns a plain host.
      #
      # @param host [String, nil]
      # @return [String] canonical host, lowercase, without port/brackets.
      def canonicalize(host)
        host.to_s.downcase.sub(/:\d+\z/, '').sub(/\.\z/, '').delete('[]')
      end

      # Does this canonicalized host smuggle a private IP via a notation
      # that `IPAddr.new` won't parse? Callers should reject any match
      # rather than try to resolve it.
      #
      # @param canonical [String] Output of {.canonicalize}.
      # @return [Boolean]
      def suspicious_numeric_host?(canonical)
        return true if canonical.match?(NUMERIC_HOST_BYPASS)

        four_octet = canonical.match(/\A(\w+)\.(\w+)\.(\w+)\.(\w+)\z/)
        return false unless four_octet

        four_octet.captures.any? { |octet| octet.match?(SUSPICIOUS_OCTET) }
      end
    end
  end
end
