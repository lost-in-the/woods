# frozen_string_literal: true

require 'spec_helper'
require 'woods/util/uuid5'
require 'woods/storage/vector_store'
require 'woods/storage/qdrant'

RSpec.describe Woods::Util::UUID5 do
  # Known-good vectors. These are published UUIDv5 values, not outputs of
  # this implementation — without them the suite would only prove the code
  # agrees with itself.
  #
  # `python.org` in the DNS namespace is the worked example in CPython's
  # own uuid documentation; `www.example.com` in the DNS namespace is the
  # vector reproduced across RFC 9562 tooling and every mainstream UUID
  # library. Both pin the version nibble (the third group starts with `5`)
  # and the variant bits (the fourth group starts with 8/9/a/b).
  describe '.generate' do
    it 'matches the published UUIDv5 for python.org in the DNS namespace' do
      expect(described_class.generate(described_class::NAMESPACE_DNS, 'python.org'))
        .to eq('886313e1-3b8a-5372-9b90-0c9aee199e5d')
    end

    it 'matches the published UUIDv5 for www.example.com in the DNS namespace' do
      expect(described_class.generate(described_class::NAMESPACE_DNS, 'www.example.com'))
        .to eq('2ed6657d-e927-568b-95e1-2665a8aea6a2')
    end

    it 'sets the version nibble to 5' do
      uuid = described_class.generate(described_class::NAMESPACE_DNS, 'anything')

      expect(uuid.split('-')[2][0]).to eq('5')
    end

    it 'sets the RFC 4122 variant bits' do
      uuid = described_class.generate(described_class::NAMESPACE_DNS, 'anything')

      expect(%w[8 9 a b]).to include(uuid.split('-')[3][0])
    end

    it 'returns a canonical lowercase UUID' do
      uuid = described_class.generate(described_class::NAMESPACE_DNS, 'Api::V1::UsersController')

      expect(uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it 'is deterministic for the same namespace and name' do
      a = described_class.generate(described_class::NAMESPACE_DNS, 'User')
      b = described_class.generate(described_class::NAMESPACE_DNS, 'User')

      expect(a).to eq(b)
    end

    it 'differs for different names' do
      a = described_class.generate(described_class::NAMESPACE_DNS, 'User')
      b = described_class.generate(described_class::NAMESPACE_DNS, 'Users')

      expect(a).not_to eq(b)
    end

    it 'differs for different namespaces' do
      other = described_class.generate(described_class::NAMESPACE_DNS, 'ns')

      expect(described_class.generate(other, 'User'))
        .not_to eq(described_class.generate(described_class::NAMESPACE_DNS, 'User'))
    end

    it 'accepts an uppercase namespace' do
      expect(described_class.generate(described_class::NAMESPACE_DNS.upcase, 'python.org'))
        .to eq('886313e1-3b8a-5372-9b90-0c9aee199e5d')
    end

    it 'rejects a namespace that is not a canonical UUID' do
      expect { described_class.generate('not-a-uuid', 'x') }
        .to raise_error(ArgumentError, /canonical UUID/)
    end

    # Encoding independence is the cross-process stability argument: the
    # gem's own suite runs under US-ASCII, hosts run under UTF-8, and a
    # point id that moved with LANG would duplicate instead of replace.
    it 'hashes the same bytes regardless of the name string encoding' do
      utf8 = 'Api::V1::UsersController'
      ascii = utf8.dup.force_encoding(Encoding::US_ASCII)

      expect(described_class.generate(described_class::NAMESPACE_DNS, ascii))
        .to eq(described_class.generate(described_class::NAMESPACE_DNS, utf8))
    end

    it 'handles a non-ASCII name' do
      expect(described_class.generate(described_class::NAMESPACE_DNS, 'Modèle'))
        .to match(/\A[0-9a-f-]{36}\z/)
    end

    # The transcode branch, which the ASCII-only case above never reaches:
    # a non-ASCII name in a non-UTF-8 encoding must be converted to UTF-8
    # bytes before hashing, not hashed in its source encoding. Latin-1
    # 'è' is one byte (0xE8), UTF-8 'è' is two (0xC3 0xA8) — hashing the
    # wrong one makes the point id depend on how the string was read.
    it 'transcodes a non-UTF-8 name to UTF-8 bytes before hashing' do
      utf8 = 'Modèle'
      latin1 = utf8.encode(Encoding::ISO_8859_1)

      expect(described_class.generate(described_class::NAMESPACE_DNS, latin1))
        .to eq(described_class.generate(described_class::NAMESPACE_DNS, utf8))
    end
  end

  describe '.uuid?' do
    it 'accepts a canonical UUID' do
      expect(described_class).to be_uuid('886313e1-3b8a-5372-9b90-0c9aee199e5d')
    end

    it 'accepts an uppercase canonical UUID' do
      expect(described_class).to be_uuid('886313E1-3B8A-5372-9B90-0C9AEE199E5D')
    end

    it 'rejects a Woods identifier' do
      expect(described_class).not_to be_uuid('Api::V1::UsersController')
    end

    it 'rejects a UUID without hyphens' do
      expect(described_class).not_to be_uuid('886313e13b8a53729b900c9aee199e5d')
    end

    it 'rejects a non-String' do
      expect(described_class).not_to be_uuid(42)
    end
  end

  # The Qdrant namespace is pinned as a literal so it can never drift, but
  # it was derived rather than invented. This asserts the derivation, which
  # is what makes the literal auditable.
  describe 'the pinned Qdrant point-id namespace' do
    it 'equals UUIDv5(DNS, "woods.qdrant.point-id")' do
      expect(Woods::Storage::VectorStore::Qdrant::POINT_ID_NAMESPACE)
        .to eq(described_class.generate(described_class::NAMESPACE_DNS, 'woods.qdrant.point-id'))
    end

    it 'is pinned to the byte-for-byte value every existing collection was written with' do
      expect(Woods::Storage::VectorStore::Qdrant::POINT_ID_NAMESPACE)
        .to eq('7eb8ae2b-670b-55ee-a474-36bd1a8dc6b4')
    end
  end
end
