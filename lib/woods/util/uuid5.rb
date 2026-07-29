# frozen_string_literal: true

require 'digest'

module Woods
  module Util
    # RFC 4122 / RFC 9562 name-based UUID version 5 (SHA-1) generation.
    #
    # Ruby's stdlib has no UUIDv5 primitive (`SecureRandom.uuid` is v4 —
    # random, therefore useless for deriving a stable id from a name), so
    # the digest is assembled here from {Digest::SHA1}.
    #
    # The output is a pure function of `(namespace, name)`: no clock, no
    # randomness, no locale, no hash-ordering. Every input to the digest is
    # a byte string derived deterministically, which is what makes the
    # result identical across processes, machines, and Ruby versions —
    # `Digest::SHA1` is a fixed standard, and the byte layout below is
    # spelled out explicitly rather than relying on any Ruby-version
    # behaviour.
    #
    # @example
    #   Woods::Util::UUID5.generate(Woods::Util::UUID5::NAMESPACE_DNS, 'python.org')
    #   # => "886313e1-3b8a-5372-9b90-0c9aee199e5d"
    #
    module UUID5
      # The predefined DNS namespace from RFC 4122 Appendix C. Present so
      # derived namespaces can be computed (and asserted) from a published
      # constant rather than a magic literal.
      NAMESPACE_DNS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'

      # Canonical 8-4-4-4-12 hex form, case-insensitive.
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      # Hex-digit group lengths of the canonical textual form.
      GROUP_LENGTHS = [8, 4, 4, 4, 12].freeze
      private_constant :GROUP_LENGTHS

      # Generate the version 5 UUID for +name+ within +namespace+.
      #
      # @param namespace [String] Namespace UUID in canonical 8-4-4-4-12 form
      # @param name [String] The name to hash within the namespace
      # @return [String] Lowercase canonical UUIDv5
      # @raise [ArgumentError] if +namespace+ is not a canonical UUID
      def self.generate(namespace, name)
        digest = Digest::SHA1.digest(pack_uuid(namespace) + name_bytes(name))
        format_uuid(apply_version_and_variant(digest.bytes.first(16)))
      end

      # Is +value+ a canonical textual UUID?
      #
      # @param value [Object]
      # @return [Boolean]
      def self.uuid?(value)
        value.is_a?(String) && UUID_PATTERN.match?(value)
      end

      # Convert a canonical UUID string into its 16 raw big-endian bytes.
      #
      # @param uuid [String]
      # @return [String] binary, 16 bytes
      # @raise [ArgumentError] if +uuid+ is not canonical
      def self.pack_uuid(uuid)
        raise ArgumentError, "Namespace is not a canonical UUID: #{uuid.inspect}" unless uuid?(uuid)

        [uuid.delete('-')].pack('H32')
      end

      # The name's UTF-8 bytes.
      #
      # UUIDv5 hashes *bytes*, so the encoding a Ruby String happens to
      # carry is load-bearing: the same characters tagged US-ASCII and
      # UTF-8 must hash identically or a re-embed under a different
      # `LANG` would produce a different point id and duplicate rather
      # than replace. ASCII-only strings already share their byte
      # sequence with UTF-8; anything else is transcoded explicitly.
      #
      # @param name [String]
      # @return [String] binary
      def self.name_bytes(name)
        str = name.to_s
        str = str.encode(Encoding::UTF_8) unless str.encoding == Encoding::UTF_8 || str.ascii_only?
        str.b
      end

      # Stamp the version (5) and RFC 4122 variant bits into the digest.
      #
      # Byte 6 holds the version in its high nibble; byte 8 holds the
      # variant in its two high bits. Both are masked before being set so
      # the surrounding hash bits survive.
      #
      # @param bytes [Array<Integer>] 16 digest bytes
      # @return [Array<Integer>] the same array, mutated
      def self.apply_version_and_variant(bytes)
        bytes[6] = (bytes[6] & 0x0f) | 0x50 # version 5
        bytes[8] = (bytes[8] & 0x3f) | 0x80 # variant RFC 4122
        bytes
      end

      # Render 16 bytes as the canonical lowercase 8-4-4-4-12 string.
      #
      # @param bytes [Array<Integer>]
      # @return [String]
      def self.format_uuid(bytes)
        hex = bytes.pack('C16').unpack1('H*')
        offset = 0
        GROUP_LENGTHS.map do |len|
          group = hex[offset, len]
          offset += len
          group
        end.join('-')
      end

      private_class_method :pack_uuid, :name_bytes, :apply_version_and_variant, :format_uuid
    end
  end
end
